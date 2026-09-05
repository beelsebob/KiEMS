%
% Tutorials / Horn Antenna
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
%% Define the horn antenna geometry, simulation box, and frequency range of
%% interest. The horn dimensions (width, height, length) and opening angle
%% jointly control the aperture area and therefore the achievable directivity;
%% the frequency range is centred at 15 GHz where the TE10 mode propagates
%% through the rectangular feed waveguide.
physical_constants;
unit = 1e-3; % all length in mm

% horn width in x-direction
horn.width  = 20;
% horn height in y-direction
horn.height = 30;
% horn length in z-direction
horn.length = 50;

horn.feed_length = 50;

horn.thickness = 2;

% horn opening angle in x, y
horn.angle = [20 20]*pi/180;

% size of the simulation box
SimBox = [200 200 200];

% frequency range of interest
f_start =  10e9;
f_stop  =  20e9;

% frequency of interest
f0 = 15e9;

% waveguide TE-mode definition
TE_mode = 'TE10';
a = horn.width;
b = horn.height;

%% FDTD Solver and Excitation Setup
%% ---------------------------------
%% Configure the FDTD time-stepper and the broadband Gaussian pulse
%% excitation. PML absorbing boundaries on all six faces prevent outgoing
%% waves from reflecting back and corrupting the far-field result. The
%% Gaussian pulse covers the entire frequency range of interest in a single
%% simulation run, making wideband characterisation efficient.
FDTD = InitFDTD('EndCriteria', 1e-4);
FDTD = SetGaussExcite(FDTD,0.5*(f_start+f_stop),0.5*(f_stop-f_start));
BC = {'PML_8' 'PML_8' 'PML_8' 'PML_8' 'PML_8' 'PML_8'}; % boundary conditions
FDTD = SetBoundaryCond( FDTD, BC );

%% CSXCAD Geometry and Mesh Initialization
%% ----------------------------------------
%% Build the Cartesian mesh that the FDTD solver will use throughout the
%% simulation. Fixed mesh lines are placed at structural boundaries (simulation
%% box edges and waveguide walls) to capture field discontinuities accurately;
%% SmoothMeshLines fills the gaps with a gradual cell-size transition, keeping
%% the maximum cell size at approximately lambda/15 to limit numerical dispersion.
% currently, openEMS cannot automatically generate a mesh
max_res = c0 / (f_stop) / unit / 15; % cell size: lambda/20
CSX = InitCSX();

% create fixed lines for the simulation box, substrate and port
mesh.x = [-SimBox(1)/2 -a/2 a/2 SimBox(1)/2];
mesh.x = SmoothMeshLines( mesh.x, max_res, 1.4); % create a smooth mesh between specified fixed mesh lines

mesh.y = [-SimBox(2)/2 -b/2 b/2 SimBox(2)/2];
mesh.y = SmoothMeshLines( mesh.y, max_res, 1.4 );

% create fixed lines for the simulation box and given number of lines inside the substrate
mesh.z = [-horn.feed_length 0 SimBox(3)-horn.feed_length ];
mesh.z = SmoothMeshLines( mesh.z, max_res, 1.4 );

CSX = DefineRectGrid( CSX, unit, mesh );

%% Horn Antenna Geometry
%% ---------------------
%% Construct the horn as a PEC metal object composed of rectangular boxes
%% (the closed feed waveguide section) and linearly-extruded polygons (the
%% four flared opening panels). The flare angle directly controls the aperture
%% area: a larger angle yields a wider aperture and therefore higher theoretical
%% gain, but also increases the physical length needed to keep phase errors small.
% horn feed rect waveguide
CSX = AddMetal(CSX, 'horn');
start = [-a/2-horn.thickness -b/2 mesh.z(1)];
stop  = [-a/2                 b/2 0];
CSX = AddBox(CSX,'horn',10,start,stop);
start = [a/2+horn.thickness -b/2 mesh.z(1)];
stop  = [a/2                 b/2 0];
CSX = AddBox(CSX,'horn',10,start,stop);
start = [-a/2-horn.thickness b/2+horn.thickness mesh.z(1)];
stop  = [ a/2+horn.thickness b/2                0];
CSX = AddBox(CSX,'horn',10,start,stop);
start = [-a/2-horn.thickness -b/2-horn.thickness mesh.z(1)];
stop  = [ a/2+horn.thickness -b/2                0];
CSX = AddBox(CSX,'horn',10,start,stop);

% horn opening
p(2,1) = a/2;
p(1,1) = 0;
p(2,2) = a/2 + sin(horn.angle(1))*horn.length;
p(1,2) = horn.length;
p(2,3) = -a/2 - sin(horn.angle(1))*horn.length;
p(1,3) = horn.length;
p(2,4) = -a/2;
p(1,4) = 0;
CSX = AddLinPoly( CSX, 'horn', 10, 1, -horn.thickness/2, p, horn.thickness, 'Transform', {'Rotate_X',horn.angle(2),'Translate',['0,' num2str(-b/2-horn.thickness/2) ',0']});
CSX = AddLinPoly( CSX, 'horn', 10, 1, -horn.thickness/2, p, horn.thickness, 'Transform', {'Rotate_X',-horn.angle(2),'Translate',['0,' num2str(b/2+horn.thickness/2) ',0']});

p(1,1) = b/2+horn.thickness;
p(2,1) = 0;
p(1,2) = b/2+horn.thickness + sin(horn.angle(2))*horn.length;
p(2,2) = horn.length;
p(1,3) = -b/2-horn.thickness - sin(horn.angle(2))*horn.length;
p(2,3) = horn.length;
p(1,4) = -b/2-horn.thickness;
p(2,4) = 0;
CSX = AddLinPoly( CSX, 'horn', 10, 0, -horn.thickness/2, p, horn.thickness, 'Transform', {'Rotate_Y',-horn.angle(2),'Translate',[ num2str(-a/2-horn.thickness/2) ',0,0']});
CSX = AddLinPoly( CSX, 'horn', 10, 0, -horn.thickness/2, p, horn.thickness, 'Transform', {'Rotate_Y',+horn.angle(2),'Translate',[ num2str(a/2+horn.thickness/2) ',0,0']});

% horn aperture
A = (a + 2*sin(horn.angle(1))*horn.length)*unit * (b + 2*sin(horn.angle(2))*horn.length)*unit;

%% Waveguide Port Excitation
%% -------------------------
%% Define a rectangular waveguide port that launches the TE10 mode into the
%% feed section and simultaneously records the incident and reflected field
%% amplitudes at every frequency. Setting the excitation flag to 1 designates
%% this port as the signal source; the ratio of reflected to incident voltage
%% waves directly gives the input reflection coefficient S11.
start=[-a/2 -b/2 mesh.z(8) ];
stop =[ a/2  b/2 mesh.z(1)+horn.feed_length/2 ];
[CSX, port] = AddRectWaveGuidePort( CSX, 0, 1, start, stop, 2, a*unit, b*unit, TE_mode, 1);

%% Near-Field to Far-Field Transformation Box
%% -------------------------------------------
%% Place the NF2FF recording surface a few cells inside the PML boundaries
%% so that it fully encloses the antenna. The bottom face is excluded via the
%% Directions flag because the waveguide feed passes through it; including that
%% face would capture conducted rather than radiated power and corrupt the
%% far-field integral.
start = [mesh.x(9) mesh.y(9) mesh.z(9)];
stop  = [mesh.x(end-8) mesh.y(end-8) mesh.z(end-8)];
[CSX nf2ff] = CreateNF2FFBox(CSX, 'nf2ff', start, stop, 'Directions', [1 1 1 1 0 1]);

%% Simulation Output Directory
%% ---------------------------
%% Create and clean the output directory that will hold the CSXCAD XML file
%% and all field-dump results. CleanupSimPath removes any data from a previous
%% run so that post-processing never accidentally reads stale files.
Sim_Path = 'tmp_Horn_Antenna';
Sim_CSX = 'horn_ant.xml';

CleanupSimPath(Sim_Path);

%% Export CSXCAD XML
%% -----------------
%% Serialize the combined FDTD settings and geometry description to an XML
%% file that the openEMS solver reads at runtime. Separating the setup script
%% from the solver binary means the same XML can be re-run with different
%% openEMS options or submitted to a remote cluster without modification.
WriteOpenEMS([Sim_Path '/' Sim_CSX], FDTD, CSX);

%% Geometry Visualization
%% ----------------------
%% Open AppCSXCAD to render the mesh and metal surfaces interactively before
%% committing to a potentially long simulation run. Visually confirming the
%% geometry catches structural errors — misplaced walls, wrong flare angles —
%% that would otherwise only become apparent from unexpected S-parameter results.
CSXGeomPlot([Sim_Path '/' Sim_CSX]);

%% Run the FDTD Simulation
%% -----------------------
%% Launch the openEMS solver on the prepared XML file and wait for convergence.
%% The solver terminates when the remaining time-domain energy in the simulation
%% volume drops below the EndCriteria threshold, confirming that all transient
%% signals have decayed and the broadband frequency response is fully captured.
RunOpenEMS(Sim_Path, Sim_CSX);

%% S-Parameter Post-Processing
%% ----------------------------
%% Calculate the port voltages and currents over the sampled frequency range to
%% extract the input impedance and reflection coefficient S11. A deep S11 notch
%% across the band confirms that the horn is well-matched to its rectangular
%% waveguide feed, ensuring most of the input power is radiated rather than
%% reflected back to the source.
freq = linspace(f_start,f_stop,201);

port = calcPort(port, Sim_Path, freq);

Zin = port.uf.tot ./ port.if.tot;
s11 = port.uf.ref ./ port.uf.inc;

plot( freq/1e9, 20*log10(abs(s11)), 'k-', 'Linewidth', 2 );
ylim([-60 0]);
grid on
title( 'reflection coefficient S_{11}' );
xlabel( 'frequency f / GHz' );
ylabel( 'reflection coefficient |S_{11}|' );

drawnow

%% Far-Field Radiation Pattern
%% ---------------------------
%% Compute the far-field directivity patterns at phi=0 and phi=90 degrees using
%% the tangential near-field data recorded on the NF2FF box. The reported Dmax
%% and aperture efficiency quantify how closely the horn approaches its
%% theoretical aperture gain, and comparing the two principal-plane cuts reveals
%% the asymmetry introduced by different E- and H-plane flare angles.

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

%% Normalized Directivity Plots
%% -----------------------------
%% Display the normalized far-field directivity versus theta for both principal
%% planes on a linear dB scale and as a polar diagram. Comparing the two cuts
%% shows the beamwidth asymmetry that arises from different E- and H-plane
%% aperture dimensions, and the polar plot gives an intuitive view of side-lobe
%% levels relative to the main beam.
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
%% -------------------------------------
%% Recompute the far field over a dense angular grid covering all azimuth and
%% elevation angles to build a complete 3D radiation pattern. The finer angular
%% sampling near the main beam captures the peak directivity accurately, while
%% coarser sampling suffices in the low-gain side-lobe region, keeping the
%% computation time manageable.
phiRange = sort( unique( [-180:5:-100 -100:2.5:-50 -50:1:50 50:2.5:100 100:5:180] ) );
thetaRange = sort( unique([ 0:1:50 50:2.:100 100:5:180 ]));

disp( 'calculating 3D far field...' );
nf2ff = CalcNF2FF(nf2ff, Sim_Path, f0, thetaRange*pi/180, phiRange*pi/180, 'Verbose',2,'Outfile','nf2ff_3D.h5');

figure
plotFF3D(nf2ff);

%% VTK Far-Field Export
%% --------------------
%% Normalize the 3D E-field pattern and write it to a VTK file for
%% visualization in ParaView or similar post-processors. Scaling by 1e-3
%% converts the pattern overlay from millimetres to metres so that it renders
%% at the correct physical size relative to the antenna structure when both
%% are loaded into the same scene.
E_far_normalized = nf2ff.E_norm{1}/max(nf2ff.E_norm{1}(:));
DumpFF2VTK([Sim_Path '/Horn_Pattern.vtk'],E_far_normalized,thetaRange,phiRange,'scale',1e-3);
