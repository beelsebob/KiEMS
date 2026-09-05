%
% Tutorials / MSL Notch-Filter
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
%% Define the physical dimensions of the filter geometry: a 50 mm microstrip
%% on a 254 µm RO4350B substrate with a 12 mm open-ended stub. The maximum
%% frequency is set to 7 GHz to capture the notch and any harmonics.
physical_constants;
unit = 1e-6; % specify everything in um
MSL_length = 50000;
MSL_width = 600;
substrate_thickness = 254;
substrate_epr = 3.66;
stub_length = 12e3;
f_max = 7e9;

%% FDTD Configuration
%% ------------------
%% A Gaussian pulse centred at ``f_max/2`` excites the full bandwidth in a
%% single simulation run. PML boundaries on the feed ends absorb outgoing
%% waves; a PEC plane closes the bottom of the mesh (ground plane).
FDTD = InitFDTD();
FDTD = SetGaussExcite( FDTD, f_max/2, f_max/2 );
BC   = {'PML_8' 'PML_8' 'MUR' 'MUR' 'PEC' 'MUR'};
FDTD = SetBoundaryCond( FDTD, BC );

%% Geometry and Mesh
%% -----------------
%% An inhomogeneous mesh is used: two closely-spaced lines at each conductor
%% edge (one 1/3 inside, one 2/3 outside) reduce staircasing error, while
%% :func:`SmoothMeshLines` grades smoothly from λ/200 at the edges to λ/50
%% in the open regions.
CSX = InitCSX();
resolution = c0/(f_max*sqrt(substrate_epr))/unit /50; % resolution of lambda/50
mesh.x = SmoothMeshLines( [0 MSL_width/2+[2*resolution/3 -resolution/3]/4], resolution/4, 1.5 ,0 );
mesh.x = SmoothMeshLines( [-MSL_length -mesh.x mesh.x MSL_length], resolution, 1.5 ,0 );
mesh.y = SmoothMeshLines( [0 MSL_width/2+[-resolution/3 +resolution/3*2]/4], resolution/4 , 1.5 ,0);
mesh.y = SmoothMeshLines( [-15*MSL_width -mesh.y mesh.y stub_length+[-resolution/3 +resolution/3*2]/4 15*MSL_width+stub_length], resolution, 1.3 ,0);
mesh.z = SmoothMeshLines( [linspace(0,substrate_thickness,5) 10*substrate_thickness], resolution );
CSX = DefineRectGrid( CSX, unit, mesh );

%% Substrate
%% ~~~~~~~~~
%% RO4350B (εr = 3.66) is modeled as a dielectric box filling the full mesh
%% footprint to ``substrate_thickness``, forming the electrical environment
%% for the microstrip.
CSX = AddMaterial( CSX, 'RO4350B' );
CSX = SetMaterialProperty( CSX, 'RO4350B', 'Epsilon', substrate_epr );
start = [mesh.x(1),   mesh.y(1),   0];
stop  = [mesh.x(end), mesh.y(end), substrate_thickness];
CSX = AddBox( CSX, 'RO4350B', 0, start, stop );

%% MSL Ports
%% ~~~~~~~~~
%% Two :func:`AddMSLPort` calls place microstrip ports at either end of the
%% line; port 1 carries the excitation and both ports record voltage at
%% ``MSL_length/3`` to measure away from the near-field of the feed.
CSX = AddMetal( CSX, 'PEC' );
portstart = [ mesh.x(1), -MSL_width/2, substrate_thickness];
portstop  = [ 0,  MSL_width/2, 0];
[CSX,port{1}] = AddMSLPort( CSX, 999, 1, 'PEC', portstart, portstop, 0, [0 0 -1], 'ExcitePort', true, 'FeedShift', 10*resolution, 'MeasPlaneShift',  MSL_length/3);

portstart = [mesh.x(end), -MSL_width/2, substrate_thickness];
portstop  = [0          ,  MSL_width/2, 0];
[CSX,port{2}] = AddMSLPort( CSX, 999, 2, 'PEC', portstart, portstop, 0, [0 0 -1], 'MeasPlaneShift',  MSL_length/3 );

%% Filter Stub
%% ~~~~~~~~~~~
%% A PEC patch on the top metal layer forms the open-ended stub; its
%% quarter-wave resonance at the frequency determined by ``stub_length``
%% creates the band-stop notch in S21.
start = [-MSL_width/2,  MSL_width/2, substrate_thickness];
stop  = [ MSL_width/2,  MSL_width/2+stub_length, substrate_thickness];
CSX = AddBox( CSX, 'PEC', 999, start, stop );

%% Run the Simulation
%% ------------------
%% The geometry is exported to an openEMS XML file; :func:`CSXGeomPlot`
%% allows a visual sanity check before the FDTD solver is invoked.
Sim_Path = 'tmp';
Sim_CSX = 'msl.xml';

CleanupSimPath(Sim_Path);

WriteOpenEMS( [Sim_Path '/' Sim_CSX], FDTD, CSX );
CSXGeomPlot( [Sim_Path '/' Sim_CSX] );
RunOpenEMS( Sim_Path, Sim_CSX );

%% Post-Processing
%% ---------------
%% :func:`calcPort` de-embeds the wave quantities from the time-domain field
%% recordings referenced to 50 Ω. S11 and S21 are plotted in dB to reveal
%% the notch frequency and return loss.
close all
f = linspace( 1e6, f_max, 1601 );
port = calcPort( port, Sim_Path, f, 'RefImpedance', 50);

s11 = port{1}.uf.ref./ port{1}.uf.inc;
s21 = port{2}.uf.ref./ port{1}.uf.inc;

plot(f/1e9,20*log10(abs(s11)),'k-','LineWidth',2);
hold on;
grid on;
plot(f/1e9,20*log10(abs(s21)),'r--','LineWidth',2);
legend('S_{11}','S_{21}');
ylabel('S-Parameter (dB)','FontSize',12);
xlabel('frequency (GHz) \rightarrow','FontSize',12);
ylim([-40 2]);

