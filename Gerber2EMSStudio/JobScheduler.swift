import Cocoa

/// Which conceptual step a Job represents -- raw value order IS chain/dependency order (a later
/// case always depends on every earlier one having already run for the same simulation). Mirrors
/// the three sub-entries a simulation's own source-list row expands into (Geometry, Simulation
/// Results, Field Viewer), not EMSPipelineStage 1:1 -- `.geometryGeneration`'s own execution always
/// ensures the underlying bridge's `.grid` stage (not just `.geometry`), so a "Show Grid" toggle
/// never needs its own separate fetch once this job has run once; `.fieldPostProcessing` has no
/// bridge stage of its own at all (EMSSimulationPipelineBridge.fieldSnapshots() is a cheap, already-
/// synchronous transform once `.results` exists) -- it's tracked here purely as a genuinely
/// separate, independently cancellable/orderable row, per the user's own request.
enum JobKind: Int, CaseIterable {
    case geometryGeneration
    case simulation
    case fieldPostProcessing

    var displayName: String {
        switch self {
        case .geometryGeneration: return "Geometry Generation"
        case .simulation: return "Simulation"
        case .fieldPostProcessing: return "Field Post Processing"
        }
    }

    /// A present-tense phrase for "Current Job: ..." style progress displays (see
    /// ProgressStatusView.State.queued's own doc comment) -- distinct from displayName (a plain noun
    /// phrase, used for Jobs-window rows) since this is meant to read naturally as "Current Job:
    /// <this> '<simulation name>'".
    var progressVerbPhrase: String {
        switch self {
        case .geometryGeneration: return "Building geometry for"
        case .simulation: return "Running simulation"
        case .fieldPostProcessing: return "Post-processing fields for"
        }
    }

    /// Every job needed to reach `target`, in execution order -- e.g. .fieldPostProcessing needs
    /// .geometryGeneration and .simulation to have already completed first. Relies on `allCases`
    /// already being in declaration (== chain) order, which it is for a raw-valued enum.
    static func chain(upTo target: JobKind) -> [JobKind] {
        allCases.filter { $0.rawValue <= target.rawValue }
    }
}

/// A job never sits in `.failed` silently forever without a chance for something to notice --
/// see JobScheduler.dismiss(_:), which the 3 tab view controllers call once they've read a
/// failure out for their own error UI (see JobScheduler's own top comment on the observer pattern).
enum JobStatus: Equatable {
    case queued
    case running
    /// Cancellation has been requested (EMSSimulationPipelineBridge.requestCancellation()) but the
    /// in-flight background call hasn't returned yet -- the job is removed from JobScheduler.jobs
    /// entirely once it does (see JobScheduler.finishExecution(_:error:)), not transitioned to some
    /// other terminal state; there's nothing further to show once cancellation is confirmed.
    case cancelling
    case failed(String)
}

/// One row a Jobs window (or a tab view controller checking its own work) cares about. A class, not
/// a struct -- JobScheduler.jobs holds the authoritative, mutated-in-place instances; an observer
/// holding onto a Job reference should treat it as "possibly stale, re-fetch by id or by (document,
/// simulationName, kind) from JobScheduler.jobs before trusting it" rather than a snapshot.
final class Job {
    let id = UUID()
    weak var document: Document?
    let simulationName: String
    let kind: JobKind
    var status: JobStatus = .queued
    var progress: EMSPipelineProgress?
    /// Set once, the moment this job transitions to .running (see JobScheduler.startNextIfIdle()) --
    /// the shared basis for estimatedSecondsRemaining below, so *any* observer (not just whichever
    /// tab VC originally requested this specific job) can show a live time estimate for whatever job
    /// is currently running -- e.g. ProgressStatusView's own "Current Job: ..." sub-section, shown
    /// while a *different* simulation's tab is sitting queued behind this one.
    var startedAt: Date?

    /// Simple linear extrapolation from elapsed time and how far through this job's current phase
    /// `progress` reports -- the same formula every tab VC already computed independently for its
    /// own job before this became a shared property; nil whenever there's nothing to extrapolate
    /// from (not yet started, no progress report yet, or a phase that reports no fraction at all --
    /// see EMSPipelineProgressPhase's own doc comment on .settingUp).
    var estimatedSecondsRemaining: Double? {
        guard let startedAt, let fraction = progress?.fraction, fraction > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        return max(0, elapsed / fraction - elapsed)
    }
    /// Set by JobScheduler.invalidate(...) when a config edit needs to invalidate a stage this job
    /// is *currently running* against -- applied once the in-flight call actually returns (see
    /// JobScheduler.finishExecution(_:error:)), never before, so the invalidation can never race
    /// the background call that's still reading/writing the same pipeline state.
    fileprivate var pendingInvalidation: EMSPipelineStage?

    fileprivate init(document: Document, simulationName: String, kind: JobKind) {
        self.document = document
        self.simulationName = simulationName
        self.kind = kind
    }

    /// A ready-to-display description of this job, for ProgressStatusView's own "Current Job: ..."
    /// sub-section (see State.queued's own doc comment) -- shared by every tab VC's own `.queued`
    /// display instead of each re-deriving the same three fields independently. nil unless this job
    /// is genuinely `.running` (a `.queued` or `.cancelling` job isn't "the current job" in the
    /// sense this sub-section means -- .cancelling in particular reads as "stopping", not "in
    /// progress", and showing its last-known progress there would be misleading).
    var progressStatusInfo: ProgressStatusView.CurrentJobInfo? {
        guard status == .running else { return nil }
        let isSettingUp = progress?.phase == .settingUp
        return ProgressStatusView.CurrentJobInfo(
            label: "\(kind.progressVerbPhrase) '\(simulationName)'",
            fraction: isSettingUp ? nil : progress?.fraction,
            timeEstimateText: isSettingUp ? nil : TimeRemainingFormatter.string(secondsRemaining: estimatedSecondsRemaining))
    }
}

/// A single, app-wide, priority-ordered job queue -- one FDTD/GPU-bound run at a time, across every
/// open document, since only one such run should realistically use the GPU simultaneously regardless
/// of which project it's for (see the user's own scoping decision this was built to). Replaces each
/// of GeometryViewController/SimulationResultsViewController/FieldViewerViewController's own
/// independent `DispatchQueue.global().async { pipeline.ensureStage(...) }` call -- which had no
/// ordering, no cancellation, and could race two ensureStage: calls on the very same
/// EMSSimulationPipelineBridge instance (no lock protects its ivars) -- with one, real, serial
/// execution queue. `jobs[0]` is always the running job, if any (see request(...)'s own doc comment
/// for why that invariant holds); everything else is in request order, most-recently-requested
/// simulation's own chain first.
///
/// Not Combine/NotificationCenter -- a plain observer-closure list, matching every other cross-object
/// callback in this app (onRunStateChanged/onProgressChanged/etc.). Always call back on the main
/// thread; every mutating method here (request/confirmCancel/invalidate/cancelAll) must itself only
/// ever be called from the main thread, since `jobs` is otherwise unguarded (the *execution* queue is
/// what actually keeps background work serialized -- see `executionQueue` -- not a lock on `jobs`
/// itself).
final class JobScheduler {
    static let shared = JobScheduler()
    private init() {}

    private(set) var jobs: [Job] = []
    private let executionQueue = DispatchQueue(label: "com.tomdavie.kicad_ems-studio.jobscheduler", qos: .userInitiated)
    private var isExecuting = false

    private struct SimKey: Hashable {
        let document: ObjectIdentifier
        let simulationName: String
    }
    /// Whether .fieldPostProcessing's (cheap, synchronous, uncached-on-the-bridge -- see JobKind's
    /// own doc comment) work has already been done for a simulation since its last .results --
    /// tracked here, not on the bridge, since nothing there distinguishes "field snapshot fetched"
    /// from "results computed" (they become true at the same instant). Cleared by invalidate(...).
    private var fieldPostProcessingDone: Set<SimKey> = []

    private var changeObservers: [() -> Void] = []
    /// Fires (main thread) after any change to `jobs` -- a new/reordered/removed job, a status
    /// change, or a progress update. Never unregistered -- every observer in this app (the Jobs
    /// window, each tab VC) lives for the app's/document's own whole lifetime, matching how
    /// onRunStateChanged/onProgressChanged etc. are never unregistered either.
    func addChangeObserver(_ observer: @escaping () -> Void) {
        changeObservers.append(observer)
    }
    private func notifyObservers() {
        for observer in changeObservers { observer() }
    }

    /// The job (if any) for this exact (document, simulationName, kind) -- for a VC to check its own
    /// work's current state after an onChange notification.
    func job(document: Document, simulationName: String, kind: JobKind) -> Job? {
        jobs.first { $0.document === document && $0.simulationName == simulationName && $0.kind == kind }
    }

    /// Requests that `target`'s whole prerequisite chain be ready for `simulationName`, reprioritizing
    /// so it becomes the front of the *pending* queue (never preempting whatever's already running).
    /// Any of the chain's jobs already queued for this simulation are reused in place (not duplicated)
    /// and pulled forward together, in their existing relative order; a kind already cached on the
    /// pipeline is skipped entirely; a kind a currently-running job is already doing for this same
    /// simulation is skipped too (that running job will itself produce the cached result this request
    /// depends on, so a duplicate queued job for it would be pure waste); and this simulation's own
    /// queued jobs for kinds *outside* this request's chain are left exactly where they are (a later,
    /// narrower request -- e.g. clicking "Geometry" after "Field Viewer" for the same simulation --
    /// must not discard the earlier, broader request's tail). Every other simulation's queued jobs are
    /// left in their own prior relative order, just pushed further back. Verified against the user's
    /// own worked walkthrough (a->geometry, then b->results, then c->results, then b->field-viewer)
    /// and against clicking Geometry/Results/Field Viewer in any order for a single simulation, step
    /// by step.
    func request(document: Document, simulationName: String, target: JobKind) {
        let pipeline = document.pipeline(forSimulationNamed: simulationName)
        let chain = JobKind.chain(upTo: target)
        let existing = jobs.filter {
            $0.document === document && $0.simulationName == simulationName && $0.status != .running
        }
        // Kinds a currently-running job is already doing for this simulation -- re-requesting one of
        // these must not spawn a duplicate queued job (see the doc comment above).
        let runningKinds = Set(jobs
            .filter { $0.document === document && $0.simulationName == simulationName && $0.status == .running }
            .map(\.kind))
        // Remove only this simulation's queued jobs for kinds this request's own chain covers, so
        // they can be rebuilt/reordered below -- NOT its queued jobs for out-of-chain kinds (those
        // belong to an earlier, broader request and must be preserved as-is).
        jobs.removeAll {
            $0.document === document && $0.simulationName == simulationName && $0.status != .running
                && chain.contains($0.kind)
        }

        var newChain: [Job] = []
        for kind in chain {
            if runningKinds.contains(kind) {
                continue
            }
            if let reused = existing.first(where: { $0.kind == kind }) {
                newChain.append(reused)
            } else if !hasCachedStage(document: document, pipeline: pipeline, simulationName: simulationName, kind: kind) {
                newChain.append(Job(document: document, simulationName: simulationName, kind: kind))
            }
        }

        // The running job (if any) is always jobs[0], and stays there: it's never in `existing`
        // (status == .running is excluded above), so it was never removed, and this always inserts
        // strictly after it -- the first non-running index, or the end if everything happens to be
        // running (impossible today, since only one job ever runs at once, but written this way
        // rather than assuming index 0 specifically).
        let insertAt = jobs.firstIndex { $0.status != .running } ?? jobs.count
        jobs.insert(contentsOf: newChain, at: insertAt)
        // startNextIfIdle() before notifyObservers() -- see its own doc comment: an observer must
        // never see a tick where one job has just finished but the next one (if any) hasn't been
        // marked .running yet, or a VC watching a chain of its own jobs (e.g. SimulationResultsViewController
        // watching both .geometryGeneration and .simulation) would misread that transient gap as
        // "nothing's running any more" and wrongly conclude the whole thing was cancelled.
        startNextIfIdle()
        notifyObservers()
    }

    private func hasCachedStage(document: Document, pipeline: EMSSimulationPipelineBridge, simulationName: String,
                                 kind: JobKind) -> Bool {
        switch kind {
        case .geometryGeneration:
            return pipeline.hasStage(.grid)
        case .simulation:
            return pipeline.hasStage(.results)
        case .fieldPostProcessing:
            return pipeline.hasStage(.results)
                && fieldPostProcessingDone.contains(SimKey(document: ObjectIdentifier(document), simulationName: simulationName))
        }
    }

    /// Every other job for the same (document, simulationName) that comes *after* `job` in chain
    /// order -- i.e. genuinely depends on it, not a prerequisite of it. Used by both a user-initiated
    /// cancel and an automatic failure, so a dependent is never left queued behind something that can
    /// now never finish.
    private func dependents(of job: Job) -> [Job] {
        jobs.filter {
            $0.id != job.id && $0.document === job.document && $0.simulationName == job.simulationName
                && $0.status != .running && $0.kind.rawValue > job.kind.rawValue
        }
    }

    /// Pure -- the dependents that would also be removed if `jobID` were cancelled right now, for a
    /// caller (the Jobs window) to show in a confirmation alert before actually calling confirmCancel.
    func previewCancel(jobID: UUID) -> [Job] {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return [] }
        return dependents(of: job)
    }

    /// Actually cancels `jobID` and every dependent previewCancel(jobID:) would have reported. A
    /// queued job is just removed outright. The running job is marked `.cancelling` and
    /// EMSSimulationPipelineBridge.requestCancellation() is called immediately -- see that method's
    /// own doc comment for how quickly that actually takes effect (within a timestep or two during an
    /// FDTD run; at the next geometry/grid checkpoint otherwise) -- but the job itself isn't removed
    /// from `jobs` until the in-flight background call actually returns (finishExecution(_:error:)),
    /// so the Jobs window keeps showing it as "Cancelling…" in the meantime rather than looking like
    /// it silently vanished while GPU work was still actually happening.
    func confirmCancel(jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        let toRemove = dependents(of: job)
        jobs.removeAll { candidate in toRemove.contains { $0.id == candidate.id } }
        if job.status == .running {
            job.status = .cancelling
            job.document?.pipeline(forSimulationNamed: job.simulationName).requestCancellation()
        } else {
            jobs.removeAll { $0.id == job.id }
        }
        notifyObservers()
    }

    /// Discards `simulationName`'s pipeline cache from `fromStage` onward -- the JobScheduler-aware
    /// replacement for calling `pipeline.invalidate(from:)` directly (which a config edit used to do
    /// straight from the main thread with no regard for whether a background ensureStage: call was
    /// simultaneously reading/writing the very same ivars -- a real, if narrow, pre-existing race).
    /// If nothing currently running for this pipeline could be affected, invalidates immediately, same
    /// as before. If the *running* job's own stage is at or after `fromStage`, cancels it first and
    /// defers the actual invalidation to run right after that background call returns, on this same
    /// scheduler's own serial queue -- never racing it.
    func invalidate(document: Document, simulationName: String, fromStage: EMSPipelineStage) {
        let affectedKind: JobKind = (fromStage == .results) ? .simulation : .geometryGeneration
        if let running = jobs.first(where: {
            $0.document === document && $0.simulationName == simulationName && $0.status == .running
        }), running.kind.rawValue >= affectedKind.rawValue {
            running.pendingInvalidation = fromStage
            confirmCancel(jobID: running.id)
        } else {
            document.pipeline(forSimulationNamed: simulationName).invalidate(from: fromStage)
            fieldPostProcessingDone.remove(SimKey(document: ObjectIdentifier(document), simulationName: simulationName))
        }
        notifyObservers()
    }

    /// Called from Document.close() -- cancels and drops every job belonging to a document that's
    /// about to go away, rather than leaving them to either run pointlessly (their own result will
    /// never be shown by anything) or hang around in the Jobs window referencing a closed document.
    func cancelAll(for document: Document) {
        for job in jobs where job.document === document && job.status == .running {
            job.document?.pipeline(forSimulationNamed: job.simulationName).requestCancellation()
        }
        jobs.removeAll { $0.document === document }
        notifyObservers()
        // isExecuting stays true until the running job's own background call actually returns and
        // calls finishExecution(_:error:) -- that's still correct: nothing else should start running
        // until this document's own in-flight GPU work has genuinely stopped.
    }

    /// Deletes `directory` once any currently-executing job has genuinely finished, rather than
    /// immediately -- called by Document.deinit for its own scratch directory instead of removing it
    /// directly. requestCancellation() (see cancelAll(for:) above) only sets a flag a running job's
    /// own background call polls at specific checkpoints (e.g. between excited ports); it is never
    /// observed *inside* the single most expensive, uninterruptible step of a run (openEMS's own
    /// SetupFDTD()/CalcECOperator() -- see EMSSimulationPipelineBridge.mm's own doc comment on
    /// setupFDTDOperator()), which can still be executing well after Document.close() returns and the
    /// Document itself deallocates. Deleting the scratch directory out from under that still-running
    /// background thread (which is chdir'd into a subdirectory of it) crashed the app the moment it
    /// next asked the OS for its own current working directory. Scheduling the deletion on this same
    /// serial executionQueue -- rather than running it inline wherever the caller happens to be --
    /// guarantees it's ordered after whatever job closure is currently occupying that queue, exactly
    /// like every other cross-thread access this class already serializes through it.
    func cleanUpDirectory(_ directory: URL) {
        executionQueue.async {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Clears a `.failed` job out of the list -- called by a tab VC once it's read the failure into
    /// its own per-index error state (matching this app's existing "each VC owns its own error UI"
    /// convention), or by the Jobs window if the user dismisses it directly. A no-op for anything not
    /// currently `.failed` (defensive -- nothing should call this on a queued/running job).
    func dismiss(jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }), job.status != .running, job.status != .cancelling else {
            return
        }
        jobs.removeAll { $0.id == jobID }
        notifyObservers()
    }

    /// Everything execute(_:context:) needs, captured up front on the main thread -- see
    /// startNextIfIdle()'s own doc comment on why: Document.pipeline(forSimulationNamed:) and
    /// .pipelineDirectory both lazily mutate the Document itself on first access (a dictionary insert,
    /// a scratch-directory creation), so calling either from executionQueue's own background thread
    /// would be a genuine, unguarded data race against the main thread's own use of that same
    /// Document -- this snapshot is what lets execute(_:context:) touch nothing but its own copies.
    private struct ExecutionContext {
        let pipeline: EMSSimulationPipelineBridge
        let config: EMSConfigBridge
        let packageDir: String
        let kicadCliPath: String
        let helperPath: String
    }

    /// Marks the next queued job `.running` and dispatches its execution, if nothing else is
    /// currently running. Deliberately does NOT call notifyObservers() itself -- every caller mutates
    /// `jobs` first (removing/failing whatever just finished, if anything), calls this, and only
    /// *then* notifies once, so observers always see one atomic, fully-settled state instead of a
    /// transient gap between one job disappearing and the next one starting (see request(...) and
    /// finishExecution(_:error:), the only two callers). Only ever called from the main thread (every
    /// mutating JobScheduler method is -- see this class's own top comment), which is what makes it
    /// safe to build ExecutionContext here.
    private func startNextIfIdle() {
        guard !isExecuting, let next = jobs.first(where: { $0.status == .queued }) else { return }
        isExecuting = true
        next.status = .running
        next.startedAt = Date()
        guard let document = next.document else {
            // The document this job belonged to is already gone -- nothing left to run against.
            // Treated as a plain, silent success (removes the job, lets the next one start) rather
            // than surfacing an error nothing is left listening for.
            finishExecution(next, error: nil)
            return
        }
        let context = ExecutionContext(
            pipeline: document.pipeline(forSimulationNamed: next.simulationName), config: document.config,
            packageDir: document.pipelineDirectory.path, kicadCliPath: AppPaths.resolveKicadCli(),
            helperPath: AppPaths.kicadQueryHelperPath)
        executionQueue.async { [weak self] in
            self?.execute(next, context: context)
        }
    }

    /// Runs entirely on `executionQueue` (a serial queue, so this is the one and only in-flight
    /// pipeline call at any time) -- touches nothing but `context`/`job` (both plain captured values/
    /// a Job whose own mutation is safe from any thread -- see Job's own doc comment) until hopping
    /// back to the main thread to report a result (see the DispatchQueue.main.async wrapping every
    /// completion below).
    private func execute(_ job: Job, context: ExecutionContext) {
        switch job.kind {
        case .geometryGeneration, .simulation:
            let stage: EMSPipelineStage = job.kind == .geometryGeneration ? .grid : .results
            do {
                try context.pipeline.ensureStage(
                    stage, config: context.config, packageDir: context.packageDir,
                    kicadCliPath: context.kicadCliPath, kicadQueryHelperPath: context.helperPath,
                    progress: { [weak self] progress in
                        DispatchQueue.main.async {
                            self?.updateProgress(job, progress)
                        }
                    })
                DispatchQueue.main.async { [weak self] in self?.finishExecution(job, error: nil) }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.finishExecution(job, error: error) }
            }
        case .fieldPostProcessing:
            // Cheap/near-instant once .results exists -- see JobKind's own doc comment -- but still
            // run through this same serial executionQueue (not just synchronously wherever
            // request(...) was called from), so it stays correctly ordered behind whatever
            // .simulation job it depends on, and so a rapid queue of field-viewer clicks across
            // several simulations doesn't do this out of order either.
            let snapshots = context.pipeline.fieldSnapshots()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !snapshots.isEmpty, let document = job.document {
                    self.fieldPostProcessingDone.insert(SimKey(document: ObjectIdentifier(document), simulationName: job.simulationName))
                    self.finishExecution(job, error: nil)
                } else {
                    self.finishExecution(job, error: NSError(
                        domain: "Gerber2EMSStudio", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "No field data available -- run Simulation first."]))
                }
            }
        }
    }

    private func updateProgress(_ job: Job, _ progress: EMSPipelineProgress) {
        job.progress = progress
        notifyObservers()
    }

    private func finishExecution(_ job: Job, error: Error?) {
        isExecuting = false
        if let error {
            if EMSSimulationPipelineBridge.isCancellationError(error as NSError) {
                jobs.removeAll { $0.id == job.id }
                if let stage = job.pendingInvalidation, let document = job.document {
                    document.pipeline(forSimulationNamed: job.simulationName).invalidate(from: stage)
                    fieldPostProcessingDone.remove(SimKey(document: ObjectIdentifier(document), simulationName: job.simulationName))
                }
            } else {
                let toRemove = dependents(of: job)
                jobs.removeAll { candidate in toRemove.contains { $0.id == candidate.id } }
                job.status = .failed(error.localizedDescription)
            }
        } else {
            jobs.removeAll { $0.id == job.id }
        }
        startNextIfIdle()
        notifyObservers()
    }
}
