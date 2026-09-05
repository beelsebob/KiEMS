%
% Stripline to Microstrip Line Transition
%
% Tested with
%  - Octave 11.3
%  - openEMS v0.37
%
% (C) 2017-2026 Thorsten Liebig <thorsten.liebig@gmx.de>

close all
clear
clc

%% Setup the Simulation
%% --------------------
%% Both conductors share an RO4350B substrate stack (εr = 3.66, lossy via
%% Kappa at 2.45 GHz). The stripline is buried at z = 0 between two ground
%% planes while the MSL runs on top; matching their impedances at the same
%% trace width determines the via radius and surrounding clearance gap.
physical_constants;
unit = 1e-6; % specify everything in um

line_length     = 15000; % line length of strip line and microstrip line
substrate_width = 10000;
air_spacer      = 4000;  % air spacer above the substrate

msl_width               = 500;
msl_substrate_thickness = 254;

strip_width               = 500;
strip_substrate_thickness = 512;

connect_via_rad =  500/2;
connect_via_gap = 1250/2;

substrate_epr    = 3.66;
substrate_kappa  = 1e-3 * 2*pi*2.45e9 * EPS0*substrate_epr; % substrate losses

f_max = 10e9;
resolution = 250;
edge_res   = 25;
feed_shift = 2500;
meas_shift = 5000;

%% Setup FDTD Parameters & Excitation Function
%% --------------------------------------------
%% A Gaussian pulse centered at f_max/2 with half-bandwidth f_max/2 sweeps
%% near-DC to 10 GHz in a single simulation run. PML_8 on the ±x port faces
%% cleanly absorbs guided modes; MUR handles the open lateral and top sides;
%% the PEC bottom is the stripline reference ground.
FDTD = InitFDTD();
FDTD = SetGaussExcite( FDTD, f_max/2, f_max/2);
BC   = {'PML_8' 'PML_8' 'MUR' 'MUR' 'PEC' 'MUR'};
FDTD = SetBoundaryCond( FDTD, BC );

%% Setup CSXCAD Geometry & Mesh
%% -----------------------------
%% The 1/3-2/3 edge offset distributes two mesh lines per conductor edge to
%% resolve near-singular fringe fields without over-refining. The x-mesh is
%% built in two passes: first a fine zone around the via clearance gap, then
%% coarser lines out to the port ends. Two polygon halves form the shared
%% reference plane at z = strip_substrate_thickness with a circular cutout
%% (radius = connect_via_gap) that prevents a short to the via conductor.
CSX = InitCSX();
edge_mesh  = [-1/3 2/3]*edge_res; % 1/3 - 2/3 rule for 2D metal edges

mesh.x = SmoothMeshLines( [-connect_via_gap 0 connect_via_gap], 2*edge_res, 1.5 );
mesh.x = SmoothMeshLines( [-line_length mesh.x line_length], resolution, 1.5);
mesh.y = SmoothMeshLines( [0 msl_width/2+edge_mesh substrate_width/2], resolution/4 , 1.5);
mesh.y = sort(unique([-mesh.y mesh.y]));
mesh.z = SmoothMeshLines( [linspace(-strip_substrate_thickness,0,5) linspace(0,strip_substrate_thickness,5) linspace(strip_substrate_thickness,msl_substrate_thickness+strip_substrate_thickness,5) 2*strip_substrate_thickness+air_spacer] , resolution );
CSX = DefineRectGrid( CSX, unit, mesh );

% Create Substrate
CSX = AddMaterial( CSX, 'RO4350B' );
CSX = SetMaterialProperty( CSX, 'RO4350B', 'Epsilon', substrate_epr, 'Kappa', substrate_kappa );
start = [mesh.x(1),   mesh.y(1),   -strip_substrate_thickness];
stop  = [mesh.x(end), mesh.y(end), +strip_substrate_thickness+msl_substrate_thickness];
CSX = AddBox( CSX, 'RO4350B', 0, start, stop );

% Create a PEC called 'metal' and 'gnd'
CSX = AddMetal( CSX, 'gnd' );
CSX = AddMetal( CSX, 'metal' );

% Create strip line port (incl. metal strip line)
start = [-line_length -strip_width/2  0];
stop  = [0            +strip_width/2  0];
[CSX,port{1}] = AddStripLinePort( CSX, 100, 1, 'metal', start, stop, strip_substrate_thickness, 'x', [0 0 -1], 'ExcitePort', true, 'FeedShift', feed_shift, 'MeasPlaneShift', meas_shift );

% Create MSL port on top
start = [line_length  -strip_width/2 strip_substrate_thickness+msl_substrate_thickness];
stop  = [0            +strip_width/2 strip_substrate_thickness];
[CSX,port{2}] = AddMSLPort( CSX, 100, 2, 'metal', start, stop, 'x', [0 0 -1], 'MeasPlaneShift', meas_shift );

% transitional via
start = [0, 0, 0];
stop  = [0, 0, strip_substrate_thickness+msl_substrate_thickness];
CSX = AddCylinder(CSX, 'metal', 100, start, stop, connect_via_rad);

% metal plane between strip line and MSL, including hole for transition
x0 = mesh.x(1);  x1 = mesh.x(end);
y0 = mesh.y(1);  y1 = mesh.y(end);

theta_l = linspace(-pi, 0, 11);
p_l = [x0, 0,                              connect_via_gap*sin(theta_l), 0,  x0 ;
       y0, y0,                             connect_via_gap*cos(theta_l), y1, y1 ];
CSX = AddPolygon( CSX, 'gnd', 1, 'z', strip_substrate_thickness, p_l);

theta_r = linspace(0, pi, 11);
p_r = [0,  x1, x1, 0,  connect_via_gap*sin(theta_r) ;
       y0, y0, y1, y1, connect_via_gap*cos(theta_r)  ];
CSX = AddPolygon( CSX, 'gnd', 1, 'z', strip_substrate_thickness, p_r);

%% Write/Show/Run the openEMS compatible xml-file
%% -----------------------------------------------
%% Serializes the geometry and FDTD settings to XML, optionally previews the
%% structure in AppCSXCAD to verify the transition geometry, then launches the
%% solver. A clean simulation directory avoids stale HDF5 field data corrupting
%% the S-parameter extraction.
Sim_Path = 'tmp';
Sim_CSX = 'strip2msl.xml';

CleanupSimPath(Sim_Path);

WriteOpenEMS( [Sim_Path '/' Sim_CSX], FDTD, CSX );
CSXGeomPlot( [Sim_Path '/' Sim_CSX] );
RunOpenEMS( Sim_Path, Sim_CSX );

%% Post-Processing
%% ---------------
%% calcPort performs a DFT on the time-domain probe recordings and de-embeds
%% incident and reflected wave voltages referenced to 50 Ohm. S11 reveals the
%% impedance match at the excitation port; S21 shows the total insertion loss
%% of the stripline-to-MSL transition across the 0-10 GHz band.
close all
f = linspace( 0, f_max, 1601 );
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

