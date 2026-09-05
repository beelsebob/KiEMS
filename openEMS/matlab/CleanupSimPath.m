function CleanupSimPath(Sim_Path, verbose)
% function CleanupSimPath(Sim_Path, verbose)
%
% Delete known openEMS output files from Sim_Path, then ensure the
% directory exists.  Only whitelisted file patterns are removed; arbitrary
% user files are left untouched.
%
% arguments:
%   Sim_Path : simulation folder
%   verbose  : (optional, default 0) set to 1 to print each deleted file
%
% Replaces the common rmdir(Sim_Path,'s') / mkdir(Sim_Path) idiom with a
% safer, selective cleanup.
%
% See also RunOpenEMS
%
% openEMS matlab interface
% -----------------------
% author: Thorsten Liebig

if nargin < 2
    verbose = 0;
end

% Patterns always deleted — extend this list as new output types are added.
always_delete = { ...
    'et', 'ht', ...                          % excitation time-series (ASCII)
    'port_ut*', 'port_it*', ...              % port voltage/current (ASCII)
    'nf2ff*.h5', ...                         % NF2FF HDF5 results
    '*.vtp', '*.vtk', '*.vtr', '*.pvd', ... % VTK visualisation files
    'openEMS_run_stats.txt', ...
    'openEMS_stats.txt', ...
    'debugCSX.xml', ...
};

for n = 1:numel(always_delete)
    entries = dir(fullfile(Sim_Path, always_delete{n}));
    for k = 1:numel(entries)
        if entries(k).isdir
            continue
        end
        f = fullfile(Sim_Path, entries(k).name);
        if verbose
            disp(['cleanup: removing ' f]);
        end
        delete(f);
    end
end

% *.h5 files are deleted when they carry the openEMS field-dump fingerprint
% attribute or contain the /nf2ff group (covers nf2ff output files
% regardless of their filename).
entries = dir(fullfile(Sim_Path, '*.h5'));
for k = 1:numel(entries)
    if entries(k).isdir
        continue
    end
    f = fullfile(Sim_Path, entries(k).name);
    is_openEMS_file = false;
    try
        ReadHDF5Attribute(f, '/', 'openEMS_HDF5_version');
        is_openEMS_file = true;
    catch
    end
    if ~is_openEMS_file
        try
            ReadHDF5Attribute(f, '/nf2ff', 'Frequency');
            is_openEMS_file = true;
        catch
        end
    end
    if is_openEMS_file
        if verbose
            disp(['cleanup: removing ' f]);
        end
        delete(f);
    end
end

if ~exist(Sim_Path, 'dir')
    mkdir(Sim_Path);
end
