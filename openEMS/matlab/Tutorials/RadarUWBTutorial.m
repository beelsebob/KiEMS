% Tutorial on time delay and signal integrity for radar
% and UWB applications
%
% Tested with
%  - Octave 11.3
%  - openEMS v0.37
%
% Author: Georg Michel, 2016

%% Simulation Overview
%% -------------------
%% This tutorial investigates the time-domain performance of a simple UWB monopole
%% antenna: delay (retardation from source to phase centre) and fidelity (normalized
%% similarity between excitation and radiated waveform). The Gaussian excitation is
%% matched to IEEE 802.15.4 UWB channel bandwidths. Dispersion and off-resonance
%% effects are clearly visible when switching between channels.

 clear;
 close all;

physical_constants;

%% Channel Configuration
%% ---------------------
%% Select one channel by uncommenting its ``suffix``, ``f_0`` and ``f_c`` lines.
%% ``f_c`` converts the IEEE 802.15.4 20 dB bandwidth to the Gaussian 3 dB bandwidth.
%% Only one block should be active at a time; the active block is ``channel4`` (default).

%suffix = "channel1";
%f_0 = 3.5e9; % center frequency of the channel
%f_c = 0.25e9 / 0.3925; % 3dB bandwidth is 0.3925 times 20dB bandwidth for Gaussian excitation

%suffix = "channel2";
%f_0 = 4.0e9; % center frequency of the channel
%f_c = 0.25e9 / 0.3925;

%suffix = "channel3";
%f_0 = 4.5e9; % center frequency of the channel
%f_c = 0.25e9 / 0.3925;

suffix = "channel4";
f_0 = 4.0e9; % center frequency of the channel
f_c = 0.5e9 / 0.3925;

%suffix = "channel5";
%f_0 = 6.5e9; % center frequency of the channel
%f_c = 0.25e9 / 0.3925;

%suffix = "channel7";
%f_0 = 6.5e9; % center frequency of the channel
%f_c = 0.5e9 / 0.3925;

%suffix = "channel4twice"; % this is just to demonstrate the degradation of the fidelity with increasing bandwidth
%f_0 = 4.0e9; % center frequency of the channel
%f_c = 1e9 / 0.3925;

tilt = 45 * pi / 180; % polarization tilt angle against co-polarization (90DEG is cross polarized)

%% Antenna and Substrate Parameters
%% ---------------------------------
%% A planar monopole on an FR4 substrate (εr = 4) is defined. The gap between
%% the feed line and the patch controls the impedance matching; ``patchsize``
%% sets the physical length of the monopole element.

% path and filename setup
Sim_Path = 'tmp';
Sim_CSX = 'uwb.xml';

% properties of the substrate
substrate.epsR = 4; % FR4
substrate.height = 0.707;
substrate.cells = 3; % thickness in cells

% size of the monopole and the gap to the ground plane
gap = 0.62; % 0.5
patchsize = 14;

% we will use millimeters
unit = 1e-3;

% set the resolution for the finer structures, e.g. the antenna gap
fineResolution = C0 / (f_0 + f_c) / sqrt(substrate.epsR) / unit / 40;
% set the resolution for the coarser structures, e.g. the surrounding air
coarseResolution = C0/(f_0 + f_c) / unit / 20;


%% Geometry Setup
%% ---------------
%% ``DetectEdges`` locates metal boundaries and applies the 1/3–2/3 edge rule
%% automatically. ``SmoothMesh`` then grades from fine resolution near the
%% antenna to coarse resolution in free space.

% initialize the CSX structure
CSX = InitCSX();

% add the properties which are used to model the antenna
CSX = AddMetal(CSX, 'Ground' );
CSX = AddMetal(CSX, 'Patch');
CSX = AddMetal(CSX, 'Line');
CSX = AddMaterial(CSX, 'Substrate' );
CSX = SetMaterialProperty(CSX, 'Substrate', 'Epsilon', substrate.epsR);

% define the supstrate and sheet-like primitives for the properties
CSX = AddBox(CSX, 'Substrate', 1, [-16, -16, -substrate.height], [16, 18, 0]);
CSX = AddBox(CSX, 'Ground', 2, [-16, -16, -substrate.height], [16, 0, -substrate.height]);
CSX = AddBox(CSX, 'Line', 2, [-1.15, -16, 0], [1.15, gap, 0]);
CSX = AddBox(CSX, 'Patch', 2, [-patchsize/2, gap, 0], [patchsize/2, gap + patchsize, 0]);

% setup a mesh
mesh.x = [];
mesh.y = [];

% two mesh lines for the metal coatings of the substrate
mesh.z = linspace(-substrate.height, 0, substrate.cells +1);

% find optimal mesh lines for the patch and ground, not yes the microstrip line
mesh = DetectEdges(CSX, mesh, 'SetProperty',{'Patch', 'Ground'}, '2D_Metal_Edge_Res', fineResolution/2);

%replace gap mesh lines which are too close by a single mesh line
tooclose = find (diff(mesh.y) < fineResolution/4);
if ~isempty(tooclose)
  mesh.y(tooclose) = (mesh.y(tooclose) + mesh.y(tooclose+1))/2;
  mesh.y(tooclose + 1) = [];
endif

% store the microstrip  edges in a temporary variable
meshline = DetectEdges(CSX, [], 'SetProperty', 'Line', '2D_Metal_Edge_Res', fineResolution/2);
% as well as the edges of the substrate (without 1/3 - 2/3 rule)
meshsubstrate = DetectEdges(CSX, [], 'SetProperty', 'Substrate');
% add only the x mesh lines of the microstrip
mesh.x = [mesh.x meshline.x];
% and only the top of the substrate, the other edges are covered by the ground plane
mesh.y = [mesh.y, meshsubstrate.y(end)]; % top of substrate

% for now we have only the edges, now calculate mesh lines in between
mesh = SmoothMesh(mesh, fineResolution);

% add the outer boundary
mesh.x = [mesh.x -60, 60];
mesh.y = [mesh.y, -60, 65];
mesh.z = [mesh.z, -46, 45];

% add coarse mesh lines for the free space
mesh = SmoothMesh(mesh, coarseResolution);

% define the grid
CSX = DefineRectGrid( CSX, unit, mesh);
% and the feeding port
[CSX, port] = AddLumpedPort( CSX, 999, 1, 50, [-1.15, meshline.y(2), -substrate.height], [1.15, meshline.y(2), 0], [0 0 1], true);

%setup a NF2FF box for the calculation of the far field
start = [mesh.x(10)     mesh.y(10)     mesh.z(10)];
stop  = [mesh.x(end-9) mesh.y(end-9) mesh.z(end-9)];
[CSX nf2ff] = CreateNF2FFBox(CSX, 'nf2ff', start, stop);

%% FDTD Configuration
%% -------------------
%% ``OverSampling`` increases the time-domain sample rate above the Nyquist
%% minimum to improve delay estimation accuracy via :func:`DelayFidelity`.
%% All six faces use PML absorbing boundaries to model an open radiating space.

% initialize the FDTD structure with excitation and open boundary conditions
FDTD = InitFDTD( 'NrTs', 30000, 'EndCriteria', 1e-5, 'OverSampling', 20);
FDTD = SetGaussExcite(FDTD, f_0, f_c );
BC   = {'PML_8' 'PML_8' 'PML_8' 'PML_8' 'PML_8' 'PML_8'};
FDTD = SetBoundaryCond(FDTD, BC );


%% Run the Simulation
%% -------------------
%% The geometry is written to XML, optionally previewed, then passed to the
%% FDTD solver. Re-run with a different channel suffix to compare results.

% remove old data, show structure, calculate new data
CleanupSimPath(Sim_Path);

% write the data to the working directory
WriteOpenEMS([Sim_Path '/' Sim_CSX], FDTD, CSX);
% show the geometry for checking
CSXGeomPlot([Sim_Path '/' Sim_CSX]);
% run the simulation
RunOpenEMS( Sim_Path, Sim_CSX);

%% Post-Processing
%% ----------------
%% :func:`DelayFidelity` computes far-field delay (in mm of equivalent path
%% length) and fidelity (0–1) vs. angle. Both are plotted using :func:`polarFF`
%% by mapping the values onto the directivity scale. Plots are saved as PNG
%% files named by channel suffix so runs can be compared side by side.

% plot amplitude and phase of the reflection coefficient
freq  = linspace(f_0-f_c, f_0+f_c, 200);
port = calcPort(port, Sim_Path, freq);
s11 = port.uf.ref ./ port.uf.inc;
s11phase = unwrap(arg(s11));
figure %("visible", "off"); % use this to plot only into files at the end of this script
ax = plotyy( freq/1e6, 20*log10(abs(s11)), freq/1e6, s11phase);
grid on
title( ['reflection coefficient ', suffix, ' S_{11}']);
xlabel( 'frequency f / MHz' );
ylabel( ax(1), 'reflection coefficient |S_{11}|' );
ylabel(ax(2), 'S_{11} phase (rad)');

% define an azimuthal trace around the monopole
phi = [0] * pi / 180;
theta = [-180:10:180] * pi / 180;

% calculate the delay, the fidelity and the farfield
[delay, fidelity, nf2ff] = DelayFidelity(nf2ff, port, Sim_Path, sin(tilt), cos(tilt), theta, phi, f_0, f_c, 'Mode', 1);

%plot the gain at (close to) f_0
f_0_nearest_ind = nthargout(2, @min, abs(nf2ff.freq -f_0));
%turn directivity into gain
nf2ff.Dmax(f_0_nearest_ind) *= nf2ff.Prad(f_0_nearest_ind) / calcPort(port, Sim_Path, nf2ff.freq(f_0_nearest_ind)).P_inc;
figure %("visible", "off");
polarFF(nf2ff, 'xaxis', 'theta', 'freq_index', f_0_nearest_ind, 'logscale', [-4, 4]);
title(["gain ", suffix, " / dBi"]);


% We trick polarFF into plotting the delay in mm because
% the axes of the vanilla polar plot can not be scaled.
plotvar = delay * C0 * 1000;
maxplot = 80;
minplot = 30;
nf2ff.Dmax(1) = 10^(max(plotvar)/10);
nf2ff.E_norm{1} = 10.^(plotvar/20);
figure %("visible", "off");
polarFF(nf2ff, 'xaxis', 'theta', 'logscale', [minplot, maxplot]);
title(["delay ", suffix, " / mm"]);

% The same for the fidelity in percent.
plotvar = fidelity * 100;
maxplot = 100;
minplot = 98;
nf2ff.Dmax(1) = 10^(max(plotvar)/10);
nf2ff.E_norm{1} = 10.^(plotvar/20);
figure %("visible", "off");
polarFF(nf2ff, 'xaxis', 'theta', 'logscale', [minplot, maxplot]);
title(["fidelity ", suffix, " / %"]);

% save the plots in order to compare them after simulating the different channels
print(1, [Sim_Path, "/s11_", suffix, ".png"]);
print(2, [Sim_Path ,"/farfield_", suffix, ".png"]);
print(3, [Sim_Path, "/delay_mm_", suffix, ".png"]);
print(4, [Sim_Path, "/fidelity_", suffix, ".png"]);
return;
