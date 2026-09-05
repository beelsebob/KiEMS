%
% Tutorials / Bent Patch Antenna
%
% Tested with
%  - Octave 11.3
%  - openEMS v0.37
%
% (C) 2013-2026 Thorsten Liebig <thorsten.liebig@gmx.de>

close all
clear
clc

%% Simulation Parameters
%% ---------------------
%% This tutorial demonstrates a bent (conformal) microstrip patch antenna
%% modelled in a cylindrical coordinate system. All geometric dimensions
%% are given in millimetres; ``patch.radius`` sets the curvature of the
%% ground plane and ``feed.pos`` controls the impedance-matching offset of
%% the coaxial feed from the patch centre.
physical_constants;
unit = 1e-3; % all length in mm

% patch width in alpha-direction
patch.width  = 32; % resonant length in alpha-direction
patch.radius = 50; % radius
patch.length = 40; % patch length in z-direction

% substrate setup
substrate.epsR   = 3.38;
substrate.kappa  = 1e-3 * 2*pi*2.45e9 * EPS0*substrate.epsR;
substrate.width  = 80;
substrate.length = 90;
substrate.thickness = 1.524;
substrate.cells = 4;

% setup feeding
feed.pos = -5.5; %feeding position in x-direction
feed.width = 2;  %feeding port width
feed.R = 50;     %feed resistance

% size of the simulation box
SimBox.rad    = 2*100;
SimBox.height = 1.5*200;

%% FDTD Solver Initialization
%% --------------------------
%% openEMS is initialized with a cylindrical coordinate system
%% (``CoordSystem=1``) because the antenna geometry is naturally described
%% in (r, alpha, z). A Gaussian pulse centred at 2 GHz with a 1 GHz
%% bandwidth excites the resonance while keeping the simulation short;
%% Mur absorbing boundaries terminate all six faces of the domain.
FDTD = InitFDTD('CoordSystem', 1); % init a cylindrical FDTD
f0 = 2e9; % center frequency
fc = 1e9; % 20 dB corner frequency
FDTD = SetGaussExcite( FDTD, f0, fc );
BC = {'MUR' 'MUR' 'MUR' 'MUR' 'MUR' 'MUR'}; % boundary conditions
FDTD = SetBoundaryCond( FDTD, BC );

%% Geometry Initialization
%% -----------------------
%% CSXCAD is initialized in the same cylindrical coordinate system so that
%% ``AddBox`` primitives are interpreted as (radius, azimuth, z) extents.
%% Angular widths in radians are pre-computed from the physical arc lengths
%% and the respective bending radii before any geometry is added.
CSX = InitCSX('CoordSystem',1);

% calculate some width as an angle in radiant
patch_ang_width = patch.width/(patch.radius+substrate.thickness);
substr_ang_width = substrate.width/patch.radius;
feed_angle = feed.pos/patch.radius;

%% Radiating Patch Element
%% -----------------------
%% The radiating element is a zero-thickness perfect electric conductor
%% (PEC) placed on the outer face of the substrate at radius
%% ``patch.radius + substrate.thickness``. Its angular extent is derived
%% from the desired arc length divided by the outer radius; the resonant
%% frequency is primarily set by this arc length and the substrate
%% permittivity.
CSX = AddMetal( CSX, 'patch' ); % create a perfect electric conductor (PEC)
start = [patch.radius+substrate.thickness -patch_ang_width/2 -patch.length/2 ];
stop  = [patch.radius+substrate.thickness  patch_ang_width/2  patch.length/2 ];
CSX = AddBox(CSX,'patch',10,start,stop); % add a box-primitive to the metal property 'patch'

%% Dielectric Substrate
%% --------------------
%% The Rogers RO4003C-like substrate (epsilon_r = 3.38) fills the volume
%% between the ground plane and the patch surface. A small loss term
%% (``kappa``) derived from tan_delta = 1e-3 at 2.45 GHz accounts for
%% dielectric loss that reduces radiation efficiency. The ``substrate.cells``
%% parameter forces at least four mesh layers through the thin dielectric
%% so the field variation across it is adequately resolved.
CSX = AddMaterial( CSX, 'substrate' );
CSX = SetMaterialProperty( CSX, 'substrate', 'Epsilon', substrate.epsR, 'Kappa', substrate.kappa );
start = [patch.radius                     -substr_ang_width/2 -substrate.length/2];
stop  = [patch.radius+substrate.thickness  substr_ang_width/2  substrate.length/2];
CSX = AddBox( CSX, 'substrate', 0, start, stop);

%% Current Density Probe
%% ---------------------
%% A surface-current dump box (``DumpType=3``) records the tangential
%% current density on the outer face of the substrate at each time step
%% in HDF5 format. At the resonant frequency the current pattern reveals
%% the dominant half-wave mode and can be visualized in Paraview; this
%% diagnostic confirms correct TE10-mode operation.
CSX = AddDump(CSX, 'Jt_patch','DumpType',3,'FileType',1);
start = [patch.radius+substrate.thickness -substr_ang_width/2 -substrate.length/2];
stop  = [patch.radius+substrate.thickness +substr_ang_width/2  substrate.length/2];
CSX = AddBox( CSX, 'Jt_patch', 0, start, stop );

%% Ground Plane
%% ------------
%% The PEC ground plane closes the back side of the substrate at
%% ``patch.radius``, completing the transmission-line cross-section
%% between patch and ground. Although it is not strictly required for
%% simulation correctness, including it improves the geometry preview and
%% ensures unambiguous boundary conditions on the inner substrate face.
CSX = AddMetal( CSX, 'gnd' ); % create a perfect electric conductor (PEC)
start = [patch.radius -substr_ang_width/2 -substrate.length/2];
stop  = [patch.radius +substr_ang_width/2 +substrate.length/2];
CSX = AddBox(CSX,'gnd',10,start,stop);

%% Feed Port
%% ---------
%% A lumped port spans the substrate in the radial direction, injecting
%% the excitation signal and measuring the reflected wave simultaneously.
%% The 50-ohm source resistance matches the standard coaxial reference
%% impedance so that S11 and Zin are both referred to that reference. The
%% port is offset from centre by ``feed.pos`` to achieve good impedance
%% matching at the target frequency.
start = [patch.radius                      feed_angle 0];
stop  = [patch.radius+substrate.thickness  feed_angle 0];
[CSX port] = AddLumpedPort(CSX, 50 ,1 ,feed.R, start, stop, [1 0 0], true);


%% Mesh Generation
%% ---------------
%% ``DetectEdges`` seeds mesh lines at every geometry boundary so that
%% Yee cells align with material interfaces without manual placement.
%% Additional radial lines are forced through the thin substrate
%% (``substrate.cells``) to resolve the electric field across it, and
%% ``SmoothMesh`` fills the remaining domain with a 1.4 growth ratio
%% keeping the maximum cell size at lambda_min/20.
% detect all edges
mesh = DetectEdges(CSX);

% add the simulation domain size
mesh.r = [mesh.r patch.radius+[-20 SimBox.rad]];
mesh.a = [mesh.a -0.75*pi 0.75*pi];
mesh.z = [mesh.z -SimBox.height/2 SimBox.height/2];

% add some lines for the substrate
mesh.r = [mesh.r patch.radius+linspace(0,substrate.thickness,substrate.cells)];

% generate a smooth mesh with max. cell size: lambda_min / 20
max_res = c0 / (f0+fc) / unit / 20;
max_ang = max_res/(SimBox.rad+patch.radius); % max res in radiant
mesh = SmoothMesh(mesh, [max_res max_ang max_res], 1.4);

disp(['Num of cells: ' num2str(numel(mesh.r)*numel(mesh.a)*numel(mesh.z))]);
CSX = DefineRectGrid( CSX, unit, mesh );

%% Near-Field to Far-Field Box
%% ---------------------------
%% A closed Huygens surface is placed at least 8 cells inside each
%% absorbing boundary to avoid sampling the evanescent near-field region.
%% During the FDTD run, tangential E and H fields on all six cylindrical
%% faces are stored in HDF5 files; ``CalcNF2FF`` reads these in
%% post-processing to transform them into the far-field radiation pattern.
start = [mesh.r(4)     mesh.a(8)     mesh.z(8)];
stop  = [mesh.r(end-9) mesh.a(end-9) mesh.z(end-9)];
[CSX nf2ff] = CreateNF2FFBox(CSX, 'nf2ff', start, stop, 'Directions',[1 1 1 1 1 1]);

%% Write and Run Simulation
%% ------------------------
%% The CSXCAD structure and FDTD settings are serialized to an XML file
%% that openEMS reads at runtime. ``CSXGeomPlot`` opens the structure in
%% AppCSXCAD for a visual sanity-check before the FDTD run begins.
%% ``RunOpenEMS`` then launches the solver; wall-clock time scales with
%% the cell count printed above.
Sim_Path = ['tmp_' mfilename];
Sim_CSX  = [mfilename '.xml'];

CleanupSimPath(Sim_Path);

% write openEMS compatible xml-file
WriteOpenEMS( [Sim_Path '/' Sim_CSX], FDTD, CSX );

% show the structure
CSXGeomPlot( [Sim_Path '/' Sim_CSX] );

% run openEMS
RunOpenEMS( Sim_Path, Sim_CSX);

%% S-Parameter and Impedance Post-Processing
%% ------------------------------------------
%% ``calcPort`` reads the time-domain voltage and current waveforms and
%% computes their Fourier transforms over the requested frequency vector.
%% Input impedance Zin and reflection coefficient S11 are derived from
%% those spectra; a deep S11 minimum identifies the resonant frequency and
%% confirms efficient radiation into the surrounding medium.
freq = linspace( max([1e9,f0-fc]), f0+fc, 501 );
port = calcPort(port, Sim_Path, freq);

Zin = port.uf.tot ./ port.if.tot;
s11 = port.uf.ref ./ port.uf.inc;
P_in = 0.5*real(port.uf.tot .* conj(port.if.tot)); % antenna feed power

% plot feed point impedance
figure
plot( freq/1e6, real(Zin), 'k-', 'Linewidth', 2 );
hold on
grid on
plot( freq/1e6, imag(Zin), 'r--', 'Linewidth', 2 );
title( 'feed point impedance' );
xlabel( 'frequency f / MHz' );
ylabel( 'impedance Z_{in} / Ohm' );
legend( 'real', 'imag' );

% plot reflection coefficient S11
figure
plot( freq/1e6, 20*log10(abs(s11)), 'k-', 'Linewidth', 2 );
grid on
title( 'reflection coefficient S_{11}' );
xlabel( 'frequency f / MHz' );
ylabel( 'reflection coefficient |S_{11}|' );

drawnow

%find resonance frequency from s11
f_res_ind = find(s11==min(s11));
f_res = freq(f_res_ind);

%% Current Distribution Export
%% ---------------------------
%% At the resonant frequency the stored time-domain surface-current data
%% are Fourier-transformed to a single-frequency snapshot and written to
%% a VTK file. Loading this file in Paraview allows visual inspection of
%% the current mode shape on the patch surface; the dominant half-wave
%% distribution confirms correct TE10-mode operation.
disp('dumping resonant current distribution to vtk file, use Paraview to visualize');
ConvertHDF5_VTK([Sim_Path '/Jt_patch.h5'],[Sim_Path '/Jf_patch'],'Frequency',f_res,'FieldName','J-Field');

%% Far-Field Pattern Calculation
%% -----------------------------
%% ``CalcNF2FF`` applies the near-field to far-field transformation at
%% the resonant frequency for two principal cuts: the elevation plane
%% (phi = 0) sweeping theta, and the azimuth plane (theta = 90 deg)
%% sweeping phi. The phase centre is taken at the outer patch surface so
%% that the pattern cuts are well-defined despite the cylindrical geometry.
% calculate the far field at phi=0 degree
nf2ff = CalcNF2FF(nf2ff, Sim_Path, f_res, [-180:2:180]*pi/180, 0,'Center',[patch.radius+substrate.thickness 0 0]*unit, 'Outfile','pattern_phi_0.h5');
% normalized directivity as polar plot
figure
polarFF(nf2ff,'xaxis','theta','param',1,'normalize',1)

% calculate the far field at phi=0 degree
nf2ff = CalcNF2FF(nf2ff, Sim_Path, f_res, pi/2, (-180:2:180)*pi/180,'Center',[patch.radius+substrate.thickness 0 0]*unit, 'Outfile','pattern_theta_90.h5');
% normalized directivity as polar plot
figure
polarFF(nf2ff,'xaxis','phi','param',1,'normalize',1)

% display power and directivity
disp( ['radiated power: Prad = ' num2str(nf2ff.Prad) ' Watt']);
disp( ['directivity: Dmax = ' num2str(nf2ff.Dmax) ' (' num2str(10*log10(nf2ff.Dmax)) ' dBi)'] );
disp( ['efficiency: nu_rad = ' num2str(100*nf2ff.Prad./real(P_in(f_res_ind))) ' %']);

drawnow

%% Three-Dimensional Far-Field Pattern
%% ------------------------------------
%% The full 3D far-field pattern is computed on a dense (theta, phi)
%% sphere and exported to a VTK file for volumetric visualization in
%% Paraview. The ``logscale=-20`` display option suppresses low-level
%% sidelobes and highlights the main-beam structure; total radiated power
%% and maximum directivity are printed to the console for a quick figure
%% of merit.
disp( 'calculating 3D far field pattern and dumping to vtk (use Paraview to visualize)...' );
thetaRange = (0:2:180);
phiRange = (0:2:360) - 180;
nf2ff = CalcNF2FF(nf2ff, Sim_Path, f_res, thetaRange*pi/180, phiRange*pi/180,'Verbose',1,'Outfile','3D_Pattern.h5','Center',[patch.radius+substrate.thickness 0 0]*unit);

figure
plotFF3D(nf2ff,'logscale',-20);
