%
% Tutorials / Conical Horn Antenna
%
% Tested with
%  - Octave 11.3
%  - openEMS v0.37
%
% (C) 2011-2026 Thorsten Liebig <thorsten.liebig@gmx.de>

close all
clear
clc

%% Simulation Parameters
%% ---------------------
%% Define the physical constants, length unit, and all geometric parameters
%% of the conical horn. ``horn.radius`` is the inner radius of the feeding
%% circular waveguide; its value sets the TE11 cut-off frequency and therefore
%% the useful bandwidth of the antenna.
physical_constants;
unit = 1e-3; % all length in mm

% horn radius
horn.radius  = 20;
% horn length in z-direction
horn.length = 50;

horn.feed_length = 50;

horn.thickness = 2;

% horn opening angle
horn.angle = 20*pi/180;

% size of the simulation box
SimBox = [100 100 100]*2;

% frequency range of interest
f_start =  10e9;
f_stop  =  20e9;

% frequency of interest
f0 = 15e9;

%% FDTD Solver and Excitation Setup
%% ---------------------------------
%% Initialise the FDTD engine and choose a Gaussian pulse excitation that
%% covers the full frequency range of interest in a single simulation run.
%% PML absorbing boundaries on all six faces prevent reflections from the
%% simulation box edges and emulate an open radiating environment.
FDTD = InitFDTD( 'NrTS', 30000, 'EndCriteria', 1e-4 );
FDTD = SetGaussExcite(FDTD,0.5*(f_start+f_stop),0.5*(f_stop-f_start));
BC = {'PML_8' 'PML_8' 'PML_8' 'PML_8' 'PML_8' 'PML_8'}; % boundary conditions
FDTD = SetBoundaryCond( FDTD, BC );

%% CSXCAD Geometry and Mesh
%% ------------------------
%% Build the Cartesian mesh that covers both the feeding waveguide (negative
%% z) and the radiation half-space above the horn aperture. Fixed lines are
%% placed at the waveguide wall and simulation-box boundaries; ``SmoothMeshLines``
%% fills in the interior at roughly lambda/15 resolution to resolve the fields
%% accurately without oversampling the free-space region.
% currently, openEMS cannot automatically generate a mesh
max_res = c0 / (f_stop) / unit / 15; % cell size: lambda/20
CSX = InitCSX();

% create fixed lines for the simulation box, substrate and port
mesh.x = [-SimBox(1)/2 -horn.radius 0 horn.radius SimBox(1)/2];
mesh.x = SmoothMeshLines( mesh.x, max_res, 1.4); % create a smooth mesh between specified fixed mesh lines

mesh.y = mesh.x;

% create fixed lines for the simulation box and given number of lines inside the substrate
mesh.z = [-horn.feed_length 0 SimBox(3) ];
mesh.z = SmoothMeshLines( mesh.z, max_res, 1.4 );

CSX = DefineRectGrid( CSX, unit, mesh );

%% Conical Horn Geometry
%% ---------------------
%% Construct the metallic horn and its circular waveguide feed as a single
%% rotationally-symmetric body. A cross-sectional polygon is defined in the
%% x-z plane and rotated 360 degrees about the z-axis using ``AddRotPoly``,
%% which approximates the circular profile on the rectangular FDTD grid.
%% The aperture area ``A`` is precomputed here for use in the aperture
%% efficiency calculation during post-processing.
% horn + waveguide, defined by a rotational polygon
CSX = AddMetal(CSX, 'Conical_Horn');
p(1,1) = horn.radius+horn.thickness;   % x-coord point 1
p(2,1) = -horn.feed_length;     % z-coord point 1
p(1,end+1) = horn.radius+horn.thickness;   % x-coord point 1
p(2,end) = 0;     % z-coord point 1
p(1,end+1) = horn.radius+horn.thickness + sin(horn.angle)*horn.length; % x-coord point 2
p(2,end) = horn.length; % y-coord point 2
p(1,end+1) = horn.radius + sin(horn.angle)*horn.length; % x-coord point 2
p(2,end) = horn.length; % y-coord point 2
p(1,end+1) = horn.radius;  % x-coord point 1
p(2,end) = 0;     % z-coord point 1
p(1,end+1) = horn.radius;   % x-coord point 1
p(2,end) = -horn.feed_length;     % z-coord point 1
CSX = AddRotPoly(CSX,'Conical_Horn',10,'x',p,'z');

% horn aperture
A = pi*((horn.radius + sin(horn.angle)*horn.length)*unit)^2;

%% Waveguide Feed Port
%% -------------------
%% Excite the dominant TE11 mode inside the circular waveguide using
%% ``AddCircWaveGuidePort``. The port spans the lower section of the feed
%% waveguide and simultaneously injects the excitation and records the
%% incident and reflected wave amplitudes needed to compute S11.
start=[-horn.radius -horn.radius mesh.z(10) ];
stop =[+horn.radius +horn.radius mesh.z(1)+horn.feed_length/2 ];
[CSX, port] = AddCircWaveGuidePort( CSX, 0, 1, start, stop, horn.radius*unit, 'TE11', 0, 1);

%% Excitation Field Dump
%% ---------------------
%% Record a 2-D slice of the electric field at a plane within the feed
%% waveguide for visual verification that the TE11 mode profile is being
%% launched correctly. Inspecting this dump before analysing results helps
%% catch port-placement errors early.
CSX = AddDump(CSX,'Exc_dump');
start=[-horn.radius -horn.radius mesh.z(8)];
stop =[+horn.radius +horn.radius mesh.z(8)];
CSX = AddBox(CSX,'Exc_dump',0,start,stop);

%% Near-Field to Far-Field Box
%% ---------------------------
%% Place a Huygens surface just inside the PML on five faces to record
%% near-field data during the FDTD run. The bottom face (-z direction) is
%% excluded because the waveguide feed reaches the lower simulation boundary,
%% making that face unsuitable for a Huygens surface.
start = [mesh.x(9) mesh.y(9) mesh.z(9)];
stop  = [mesh.x(end-8) mesh.y(end-8) mesh.z(end-8)];
[CSX nf2ff] = CreateNF2FFBox(CSX, 'nf2ff', start, stop, 'Directions', [1 1 1 1 0 1]);

%% Simulation Folder Setup
%% -----------------------
%% Create a clean working directory for the simulation output files.
%% Removing any previous results avoids accidentally mixing data from
%% different simulation runs during post-processing.
Sim_Path = 'tmp';
Sim_CSX = 'horn_ant.xml';

CleanupSimPath(Sim_Path);

%% Write OpenEMS XML File
%% ----------------------
%% Serialise the complete simulation setup — FDTD parameters, boundary
%% conditions, geometry, ports and field monitors — into a single XML file
%% that the openEMS solver reads at runtime.
WriteOpenEMS( [Sim_Path '/' Sim_CSX], FDTD, CSX );

%% Preview Geometry
%% ----------------
%% Open the AppCSXCAD viewer to inspect the mesh and geometry before
%% committing to a full simulation run. Confirming that the horn cross-section
%% and port placement look correct here can save significant compute time.
CSXGeomPlot( [Sim_Path '/' Sim_CSX] );

%% Run Simulation
%% --------------
%% Launch the openEMS FDTD solver. The engine iterates time steps until the
%% stored energy decays below the ``EndCriteria`` threshold, ensuring the
%% Fourier-transformed port signals are fully converged before post-processing.
RunOpenEMS( Sim_Path, Sim_CSX);

%% Post-Processing and S-Parameter Plot
%% -------------------------------------
%% Transform the recorded port voltages and currents from the time domain to
%% the frequency domain and derive the input reflection coefficient S11.
%% A large negative S11 across the band confirms good impedance matching
%% between the waveguide feed and the radiating aperture.
freq = linspace(f_start,f_stop,201);

port = calcPort(port, Sim_Path, freq);

Zin = port.uf.tot ./ port.if.tot;
s11 = port.uf.ref ./ port.uf.inc;

% plot reflection coefficient S11
figure
plot( freq/1e9, 20*log10(abs(s11)), 'k-', 'Linewidth', 2 );
ylim([-60 0]);
grid on
title( 'reflection coefficient S_{11}' );
xlabel( 'frequency f / GHz' );
ylabel( 'reflection coefficient |S_{11}|' );

drawnow

%% Far-Field Radiation Patterns
%% ----------------------------
%% Invoke the NF2FF transformation at the centre frequency to obtain the
%% antenna directivity as a function of elevation angle for two orthogonal
%% azimuth cuts (phi = 0 and phi = 90 degrees). The aperture efficiency
%% ``e_a`` relates the achieved directivity to the theoretical maximum for
%% a uniformly illuminated aperture of the same physical area.

% calculate the far field at phi=0 degrees and at phi=90 degrees
thetaRange = (0:2:359) - 180;
disp( 'calculating far field at phi=[0 90] deg...' );
nf2ff = CalcNF2FF(nf2ff, Sim_Path, f0, thetaRange*pi/180, [0 90]*pi/180);

Dlog=10*log10(nf2ff.Dmax);
G_a = 4*pi*A/(c0/f0)^2;
e_a = nf2ff.Dmax/G_a;

% display some antenna parameter
disp( ['radiated power: Prad = ' num2str(nf2ff.Prad) ' Watt']);
disp( ['directivity: Dmax = ' num2str(Dlog) ' dBi'] );
disp( ['aperture efficiency: e_a = ' num2str(e_a*100) '%'] );

%% Normalised Directivity Plots
%% ----------------------------
%% Display the elevation-angle radiation pattern on a linear dB scale and
%% as a polar diagram for both azimuth cuts. The polar plot reveals the
%% main-lobe beamwidth and side-lobe levels that characterise the antenna's
%% angular selectivity and gain performance.
% normalized directivity
figure
plotFFdB(nf2ff,'xaxis','theta','param',[1 2]);
drawnow
%   D_log = 20*log10(nf2ff.E_norm{1}/max(max(nf2ff.E_norm{1})));
%   D_log = D_log + 10*log10(nf2ff.Dmax);
%   plot( nf2ff.theta, D_log(:,1) ,'k-', nf2ff.theta, D_log(:,2) ,'r-' );

% polar plot
figure
polarFF(nf2ff,'xaxis','theta','param',[1 2],'logscale',[-40 20], 'xtics', 12);
drawnow
%   polar( nf2ff.theta, nf2ff.E_norm{1}(:,1) )

%% Three-Dimensional Far-Field Pattern
%% ------------------------------------
%% Compute the full 3-D radiation pattern by sweeping over a dense grid of
%% theta and phi angles. Finer angular spacing is used near the main lobe
%% and coarser spacing elsewhere to keep the NF2FF computation fast while
%% preserving pattern detail where it matters most.
phiRange = sort( unique( [-180:5:-100 -100:2.5:-50 -50:1:50 50:2.5:100 100:5:180] ) );
thetaRange = sort( unique([ 0:1:50 50:2.:100 100:5:180 ]));

disp( 'calculating 3D far field...' );
nf2ff = CalcNF2FF(nf2ff, Sim_Path, f0, thetaRange*pi/180, phiRange*pi/180, 'Verbose',2,'Outfile','nf2ff_3D.h5');

figure
plotFF3D(nf2ff);        % plot liear 3D far field

%% Export Pattern to VTK
%% ----------------------
%% Normalise the electric far-field amplitude to its peak value and write
%% the result to a VTK file so the 3-D radiation pattern can be examined
%% interactively in ParaView or similar tools. The ``scale`` argument
%% converts the spatial coordinates from mm to m for correct visualisation.
E_far_normalized = nf2ff.E_norm{1}/max(nf2ff.E_norm{1}(:));
DumpFF2VTK([Sim_Path '/Conical_Horn_Pattern.vtk'],E_far_normalized,thetaRange,phiRange,'scale',1e-3);
