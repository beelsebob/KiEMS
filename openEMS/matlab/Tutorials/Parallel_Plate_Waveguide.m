%
% Tutorials / Parallel Plate Waveguide
%
% Tested with
%  - Octave 11.3
%  - openEMS v0.37
%
% (C) 2011,2012 Sebastian Held <sebastian.held@gmx.de>
% (C) 2012-2026 Thorsten Liebig <thorsten.liebig@gmx.de>

close all
clear
clc

%% FDTD Parameters and Boundary Conditions
%% -----------------------------------------
%% Run 100 time steps with a 10 MHz sinusoidal excitation to reach steady
%% state quickly. PEC boundaries on ±y model the conducting plates; PMC on
%% ±x makes the structure periodic in x; Mur ABCs on ±z absorb outgoing waves.

% init and define FDTD parameter
FDTD = InitFDTD(200,0,'OverSampling',50);
FDTD = SetSinusExcite(FDTD,10e6);
BC = {'PMC' 'PMC' 'PEC' 'PEC' 'MUR' 'MUR'};
FDTD = SetBoundaryCond(FDTD,BC);

%% CSXCAD Geometry and Mesh
%% -------------------------
%% All coordinates are in metres. The uniform 1 m mesh spans ±10 m in x
%% and y (the plate aperture) and −10 to 30 m in z, giving 30 cells of
%% propagation distance beyond the source plane.

% init and define FDTD mesh
CSX = InitCSX();
mesh.x = -10:10;
mesh.y = -10:10;
mesh.z = -10:30;
CSX = DefineRectGrid(CSX, 1, mesh);

%% Excitation
%% ----------
%% A y-polarised (E_y) uniform-field source at z = 0 launches the TEM
%% mode. The excitation box covers the full cross-section to produce a
%% spatially uniform plane-wave front.

% define the excitation
CSX = AddExcitation(CSX,'excitation',0,[0 1 0]);
CSX = AddBox(CSX,'excitation',0,[-10 -10 0],[10 10 0]);

%% Field Dump
%% ----------
%% Record the time-domain E-field in the xz mid-plane (y = 0) so Paraview
%% can animate wave propagation along z after the simulation completes.

% define a time domain e-field dump box
CSX = AddDump(CSX,'Et','DumpMode',1);
CSX = AddBox(CSX,'Et',0,[-10 0 -10],[10 0 30]);

%% Write, Visualize and Run
%% -------------------------
%% Serialize the model to XML, open AppCSXCAD to verify the geometry, then
%% launch the FDTD engine. Load the Et_*.vtr output files in Paraview to
%% animate the propagating wave.

% remove old simulation results (if exist)
CleanupSimPath('tmp');

% write openEMS xml data file
WriteOpenEMS('tmp/tmp.xml',FDTD,CSX);

% view defined structure
CSXGeomPlot( 'tmp/tmp.xml' );

% run openEMS simulation
RunOpenEMS('tmp','tmp.xml','-vvv');

disp('use Paraview to visualize the FDTD result...');
