function [port nf2ff] = Patch_Antenna_Array(Sim_Path, postproc_only, show_structure, xpos, caps, resist, active )
% [port nf2ff] = Patch_Antenna_Array(Sim_Path, postproc_only, show_structure, xpos, caps, resist, active )
%
% Script to setup the patch array as described in [1].
% Run main script in Patch_Antenna_Phased_Array.m instead!
%
% Sim_Path: Simulation path
% postproc_only: set to post process only 0/1
% show_structure: show the structure in AppCSXCAD 0/1
% xpos: the x-position for each antenna is defined
% caps: the port capacity (will override active port)
% resist: port resistance
% active: switch port active
%
% References:
% [1] Y. Yusuf and X. Gong, “A low-cost patch antenna phased array with
%   analog beam steering using mutual coupling and reactive loading,” IEEE
%   Antennas Wireless Propag. Lett., vol. 7, pp. 81–84, 2008.
%
% Tested with
%  - Octave 11.3
%  - openEMS v0.37
%
% (C) 2013-2026 Thorsten Liebig <thorsten.liebig@gmx.de>

% example
% xpos = [-41 0 41];
% caps = [0.2e-12 0 0.2e-12];
% active = [0 1 0];
% resist = [50 50 50];

%% Simulation Parameters
%% ---------------------
%% This function builds and optionally runs a microstrip patch antenna array
%% following the reactive-loading beam-steering design of Yusuf & Gong [1].
%% Each element shares the same patch geometry; the caller supplies xpos to
%% set element spacing and caps/resist/active to configure each port as
%% excited, terminated, or reactively loaded with a capacitor.
physical_constants;
unit = 1e-3; % all length in mm

% patch geometry setup
patch.W  = 35;  % width
patch.L = 28.3; % length
patch.Ws = 3.8; % width of feeding stub
patch.Gs = 1;   % width of feeding gab
patch.l = 6;    % length of feeding stub
patch.y0 = 10;  % depth of feeding stub into into patch

% patch resonance frequency
f0 = 3e9;

%substrate setup
substrate.name = 'Ro3003';
substrate.epsR   = 3;
substrate.kappa  = 0.0013 * 2*pi*f0 * EPS0*substrate.epsR;
substrate.thickness = 1.524;
substrate.cells = 4;

substrate.width = patch.W + max(xpos) - min(xpos) + 4*patch.l;
substrate.length = 3*patch.l + patch.L;

% size of the simulation box
AirSpacer = [50 50 30];

edge_res = [-1/3 2/3]*1;

%% FDTD Parameters and Excitation
%% --------------------------------
%% A Gaussian pulse centred at f0 = 3 GHz with a 2 GHz corner frequency
%% provides wideband S-parameter coverage in a single simulation run.
%% Open (PML) boundaries on all six faces (BC = 3) absorb outgoing radiation
%% without reflections, which is essential for accurate antenna patterns.
fc = 2e9; % 20 dB corner frequency
FDTD = InitFDTD( 'EndCriteria', 1e-4 );
FDTD = SetGaussExcite( FDTD, f0, fc );
BC = [1 1 1 1 1 1]*3;
FDTD = SetBoundaryCond( FDTD, BC );

%% CSXCAD Geometry and Mesh Initialization
%% -----------------------------------------
%% Initialize the CSXCAD container and empty mesh-line vectors. Mesh lines
%% are accumulated incrementally as each geometry object is added; a later
%% smoothing step converts them into a graded, physically accurate grid.
CSX = InitCSX();

mesh.x = [];
mesh.y = [];
mesh.z = [];

%% Patch Elements and Feed Ports
%% ------------------------------
%% Build each radiating patch as two PEC wings separated by a coplanar gap,
%% with a microstrip feed stub inset by y0 into the patch for impedance
%% matching. Ports are placed at the stub base and configured as excited,
%% resistively terminated, or capacitively loaded depending on the arguments.
CSX = AddMetal( CSX, 'patch' ); % create a perfect electric conductor (PEC)

for port_nr=1:numel(xpos)
    start = [xpos(port_nr)-patch.W/2           patch.l         substrate.thickness];
    stop  = [xpos(port_nr)-patch.Ws/2-patch.Gs patch.l+patch.L substrate.thickness];
    CSX = AddBox(CSX,'patch',10, start, stop);
    mesh.x = [mesh.x xpos(port_nr)-patch.W/2-edge_res];

    start = [xpos(port_nr)+patch.W/2           patch.l         substrate.thickness];
    stop  = [xpos(port_nr)+patch.Ws/2+patch.Gs patch.l+patch.L substrate.thickness];
    CSX = AddBox(CSX,'patch',10, start, stop);
    mesh.x = [mesh.x xpos(port_nr)+patch.W/2+edge_res];

    mesh.y = [mesh.y patch.l-edge_res patch.l+patch.L+edge_res];

    start = [xpos(port_nr)-patch.Ws/2-patch.Gs patch.l+patch.y0 substrate.thickness];
    stop  = [xpos(port_nr)+patch.Ws/2+patch.Gs patch.l+patch.L  substrate.thickness];
    CSX = AddBox(CSX,'patch',10, start, stop);

    % feed line
    start = [xpos(port_nr)-patch.Ws/2 patch.l+patch.y0 substrate.thickness];
    stop  = [xpos(port_nr)+patch.Ws/2 0                substrate.thickness];
    CSX = AddBox(CSX,'patch',10, start, stop);

    mesh.x = [mesh.x xpos(port_nr)+linspace(-patch.Ws/2-patch.Gs,-patch.Ws/2,3) xpos(port_nr)+linspace(patch.Ws/2,patch.Ws/2+patch.Gs,3)];

    start = [xpos(port_nr)-patch.Ws/2 0 0];
    stop  = [xpos(port_nr)+patch.Ws/2 0 substrate.thickness];
    if (caps(port_nr)>0)
        CSX = AddLumpedElement(CSX, ['C_' num2str(port_nr)], 2, 'C', caps(port_nr));
        CSX = AddBox(CSX,['C_' num2str(port_nr)],10, start, stop);

        [CSX port{port_nr}] = AddLumpedPort(CSX, 5 ,port_nr ,inf, start, stop, [0 0 1], 0);
    else
        % feed port
        [CSX port{port_nr}] = AddLumpedPort(CSX, 5 ,port_nr, resist(port_nr), start, stop, [0 0 1], active(port_nr));
    end
end

%% Dielectric Substrate
%% --------------------
%% Model the Ro3003 laminate as a lossy dielectric slab spanning the full
%% array footprint. The conductivity is derived from the material loss tangent
%% at f0, so substrate losses are accurately captured in S-parameter results.
CSX = AddMaterial( CSX, substrate.name );
CSX = SetMaterialProperty( CSX, substrate.name, 'Epsilon', substrate.epsR, 'Kappa', substrate.kappa );
start = [-substrate.width/2 0                0];
stop  = [ substrate.width/2 substrate.length substrate.thickness];
CSX = AddBox( CSX, substrate.name, 0, start, stop );

mesh.x = [mesh.x start(1) stop(1)];
mesh.y = [mesh.y start(2) stop(2)];

% add extra cells to discretize the substrate thickness
mesh.z = [linspace(0,substrate.thickness,substrate.cells+1) mesh.z];

%% Ground Plane
%% ------------
%% Add a PEC ground plane coincident with the bottom face of the substrate
%% (z = 0). Together with the patch metallization it forms the resonant
%% microstrip cavity that governs radiation efficiency and bandwidth.
CSX = AddMetal( CSX, 'gnd' ); % create a perfect electric conductor (PEC)
start(3)=0;
stop(3) =0;
CSX = AddBox(CSX,'gnd',10,start,stop);

%% Mesh Finalization
%% ------------------
%% A first smoothing pass coalesces the accumulated key lines to a 2 mm
%% maximum step; air-spacer lines are then appended around the structure.
%% A second pass enforces a lambda/20 cell-size limit at the highest
%% frequency (f0 + fc) to maintain numerical accuracy across the bandwidth.
% generate a smooth mesh with max. cell size: lambda_min / 20
mesh = SmoothMesh(mesh, 2, 1.3);
mesh.x = [mesh.x min(mesh.x)-AirSpacer(1) max(mesh.x)+AirSpacer(1)];
mesh.y = [mesh.y min(mesh.y)-AirSpacer(2) max(mesh.y)+AirSpacer(2)];
mesh.z = [mesh.z min(mesh.z)-AirSpacer(3) max(mesh.z)+2*AirSpacer(3)];

mesh = SmoothMesh(mesh, c0 / (f0+fc) / unit / 20, 1.3);

%% Near-Field to Far-Field Box
%% ----------------------------
%% Place the NF2FF integration surface 3 cells inside each absorbing
%% boundary where the fields are well-converged and evanescent components
%% have decayed. PML layers are added afterwards and the completed mesh is
%% committed to CSXCAD with DefineRectGrid.
start = [mesh.x(4)     mesh.y(4)     mesh.z(4)];
stop  = [mesh.x(end-3) mesh.y(end-3) mesh.z(end-3)];
[CSX nf2ff] = CreateNF2FFBox(CSX, 'nf2ff', start, stop);

mesh = AddPML(mesh,(BC==3)*8);
CSX = DefineRectGrid(CSX, unit, mesh);

%% Prepare Simulation Folder
%% --------------------------
%% Remove any previous results in Sim_Path so the solver starts from a
%% clean state. The CSX filename is fixed to patch_array.xml; the calling
%% script (Patch_Antenna_Phased_Array.m) supplies Sim_Path so that
%% multiple array configurations can run in separate directories in parallel.
Sim_CSX = 'patch_array.xml';

if (postproc_only==0)
    CleanupSimPath(Sim_Path);

    %% Write Model to XML
    %% -------------------
    %% Serialize the FDTD setup and CSXCAD geometry to an XML file that the
    %% openEMS engine reads at start-up. This file fully describes the
    %% simulation so it can be re-run or inspected without the Octave script.
    WriteOpenEMS( [Sim_Path '/' Sim_CSX], FDTD, CSX );

    %% Visualize Structure
    %% --------------------
    %% Open AppCSXCAD to display the geometry before running the solver.
    %% This is optional (controlled by show_structure) but useful for verifying
    %% mesh density, port placement, and substrate extent before a long run.
    if (show_structure>0)
        CSXGeomPlot( [Sim_Path '/' Sim_CSX] );
    end

    %% Run openEMS Solver
    %% -------------------
    %% Launch the FDTD engine in Sim_Path. The engine reads patch_array.xml,
    %% steps through time until the end criterion is met, and writes port
    %% voltage/current data and the NF2FF field snapshots to the same folder.
    RunOpenEMS( Sim_Path, Sim_CSX);
end

