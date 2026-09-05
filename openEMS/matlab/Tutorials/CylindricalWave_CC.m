%
% Tutorials / Cylindrical-Wave Cylindrical Coordinates
%
% Tested with
%  - Octave 11.3
%  - openEMS v0.37
%
% (C) 2011-2026 Thorsten Liebig <thorsten.liebig@gmx.de>

close all
clear
clc

%% Setup the Simulation
%% ---------------------
%% Define the simulation domain radius, mesh resolution, and five nested
%% cylindrical sub-grids whose boundaries progressively double the azimuthal
%% cell count, preventing over-sampling of the fields near the axis.
physical_constants
mesh_res = 10;      %desired mesh resolution
radius = 2560;      %simulation domain radius
split = ['80,160,320,640,1280']; %radii to split the mesh into sub-grids
split_N = 5;        %number of nested sub-grids
heigth = mesh_res*4;

f0 = 1e9;

exite_offset = 1300;
excite_angle = 45;

%% FDTD Parameters and Excitation
%% --------------------------------
%% ``CoordSystem=1`` selects cylindrical coordinates; ``MultiGrid`` activates
%% the nested sub-grid engine. A PML on the outer radial face absorbs the
%% outgoing cylindrical wave; all other boundaries default to PEC.
FDTD = InitFDTD('NrTS', 100000, 'EndCriteria', 1e-4, 'CoordSystem', 1, 'MultiGrid', split);
FDTD = SetGaussExcite(FDTD,f0,f0/2);
BC = [0 3 0 0 0 0];             % pml in positive r-direction
FDTD = SetBoundaryCond(FDTD,BC);

%% CSXCAD Geometry and Mesh
%% -------------------------
%% The outermost sub-domain carries 50 x 2^5 = 1600 azimuthal lines; each
%% inner sub-grid halves this count so angular resolution scales with cell
%% size. ``SmoothMeshLines`` distributes radial and axial lines uniformly.
% 50 mesh lines for the inner most mesh
% increase the total number of meshlines in alpha direcion for all sub-grids
N_alpha = 50 * 2^split_N + 1;

CSX = InitCSX('CoordSystem',1);
mesh.r = SmoothMeshLines([0 radius],mesh_res);
mesh.a = linspace(-pi,pi,N_alpha);
mesh.z = SmoothMeshLines([-heigth/2 0 heigth/2],mesh_res);
CSX = DefineRectGrid(CSX, 1e-3,mesh);

%% Dipole Excitation
%% ------------------
%% A z-directed electric-current source placed off-centre at 1300 mm radius
%% and 45 degree azimuth launches an asymmetric cylindrical wave, exercising
%% the multigrid across its full radial extent.
start = [exite_offset excite_angle/180*pi-0.001 -20];
stop =  [exite_offset excite_angle/180*pi+0.001  20];
if (exite_offset==0)
    start(2) = mesh.a(1);
    stop(2)  = mesh.a(1);
end
CSX = AddExcitation(CSX,'excite',1,[0 0 1]);
CSX = AddBox(CSX,'excite',0 ,start,stop);

%% Field Dump Boxes
%% -----------------
%% Two overlapping dump regions cover the full r-alpha plane at z = 0.
%% The time-domain VTK dump is sub-sampled for Paraview; the frequency-domain
%% HDF5 dump stores the complex E-field phasor at f0 for post-processing.
start = [mesh.r(1)   mesh.a(1)   0];
stop =  [mesh.r(end-8) mesh.a(end) 0];

% time domain vtk dump
CSX = AddDump(CSX,'Et_ra','DumpType',0,'FileType',0,'SubSampling','4,10,1');
CSX = AddBox(CSX,'Et_ra',0 , start,stop);

% frequency domain hdf5 dump
CSX = AddDump(CSX,'Ef_ra','DumpType',10,'FileType',1,'SubSampling','2,2,2','Frequency',f0);
CSX = AddBox(CSX,'Ef_ra',0 , start,stop);

%% Write and Run
%% --------------
%% Serialize the simulation model to XML and invoke the openEMS solver.
%% ``CleanupSimPath`` removes stale results from any previous run.
Sim_Path = 'tmp';
Sim_CSX = '2D_CC_Wave.xml';

CleanupSimPath(Sim_Path);

WriteOpenEMS([Sim_Path '/' Sim_CSX],FDTD,CSX);
RunOpenEMS(Sim_Path, Sim_CSX);

%% Paraview Visualization
%% -----------------------
%% The time-domain VTK dump can be opened in Paraview to animate the
%% propagating wave front directly on the cylindrical mesh.
disp('use Paraview to visualize the vtk field dump...');

%% Post-processing and Phase Animation
%% -------------------------------------
%% Read the frequency-domain HDF5 dump, convert the cylindrical mesh to
%% Cartesian coordinates, then animate the E_z phasor over 0-360 degrees
%% to visualise the full cylindrical wave pattern.
[field mesh_h5] = ReadHDF5Dump([Sim_Path '/Ef_ra.h5']);

r = mesh_h5.lines{1};
a = mesh_h5.lines{2};
a(end+1) = a(1);            %closeup mesh for visualization
[R A] = ndgrid(r,a);
X = R.*cos(A);
Y = R.*sin(A);

Ez = squeeze(field.FD.values{1}(:,:,1,3));
Ez(:,end+1) = Ez(:,1);      %closeup mesh for visualization

E_max = max(max(abs(Ez)));  %get maximum E_z amplitude

while 1
    for ph = linspace(0,360,41) %animate phase from 0..360 degree
        surf(X,Y,real(Ez*exp(1j*ph*pi/180)),'EdgeColor','none')
        caxis([-E_max E_max]/10)
        zlim([-E_max E_max])
        pause(0.3)
    end
end
