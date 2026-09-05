function setup()
% function setup()
%
% setup openEMS Matlab/octave interface
%
% openEMS matlab/octave interface
% -----------------------
% author: Thorsten Liebig (2011-2017)

disp('setting up openEMS matlab/octave interface')

% cd to directory of this file and restore current path at the end
current_path = pwd;
dir  = fileparts( mfilename('fullpath') );
cd(dir);

if isOctave()
    disp('compiling oct files')
    fflush(stdout);
    if isunix
        hdf5lib_dir = '';
        hdf5inc_dir = '';
        if ismac
            [res, hdf5_prefix] = unix('brew --prefix hdf5');
            if res == 0
                hdf5_prefix = strtrim(hdf5_prefix);
                hdf5lib_dir = [hdf5_prefix '/lib'];
                hdf5inc_dir = [hdf5_prefix '/include'];
            end
        else
            % Linux: try pkg-config first (handles distro naming variants).
            % Try hdf5-serial first: on Debian/Ubuntu, octave-dev pulls in
            % libhdf5-openmpi-dev, which makes the plain 'hdf5' pkg-config
            % entry point at the MPI-enabled path that requires mpi.h.
            % 'hdf5-serial' explicitly selects the serial variant.
            pkg_config_found = false;
            for pkg = {'hdf5-serial', 'hdf5'}
                [res, cflags] = unix(['pkg-config --cflags ' pkg{1} ' 2>/dev/null']);
                [res2, libs]  = unix(['pkg-config --libs-only-L ' pkg{1} ' 2>/dev/null']);
                if res == 0 && res2 == 0
                    pkg_config_found = true;
                    % extract -I and -L paths (may be empty if in default system paths)
                    tok = regexp(strtrim(cflags), '-I(\S+)', 'tokens');
                    if ~isempty(tok), hdf5inc_dir = tok{1}{1}; end
                    tok = regexp(strtrim(libs), '-L(\S+)', 'tokens');
                    if ~isempty(tok), hdf5lib_dir = tok{1}{1}; end
                    break
                end
            end
            % fall back to find only if pkg-config was not available at all
            if ~pkg_config_found && (isempty(hdf5lib_dir) || isempty(hdf5inc_dir))
                [~, fn_so] = unix('find /usr/lib -name libhdf5.so | head -1');
                [~, fn_h]  = unix('find /usr/include -name hdf5.h | grep -v opencv | sort -r | head -1');
                fn_so = strtrim(fn_so);
                fn_h  = strtrim(fn_h);
                if ~isempty(fn_so), [hdf5lib_dir, ~, ~] = fileparts(fn_so); end
                if ~isempty(fn_h),  [hdf5inc_dir, ~, ~] = fileparts(fn_h);  end
            end
        end
        oct_files = {'h5readatt_octave.cc', 'h5writemode_octave.cc'};
        try
            if ~isempty(hdf5lib_dir) && ~isempty(hdf5inc_dir)
                disp(["HDF5 library path found at: " hdf5lib_dir])
                disp(["HDF5 include path found at: " hdf5inc_dir])
            end
            for k = 1:numel(oct_files)
                if ~isempty(hdf5lib_dir) && ~isempty(hdf5inc_dir)
                    mkoctfile(oct_files{k}, ["-L" hdf5lib_dir], ["-I" hdf5inc_dir], "-lhdf5")
                else
                    mkoctfile('-lhdf5', oct_files{k})
                end
            end
        catch e
            % Distinguish "mkoctfile binary missing" from a real compile error
            % so the user gets an actionable install hint in the former case.
            if ~isempty(strfind(e.message, 'unable to find the mkoctfile'))
                error(['mkoctfile not found - cannot compile oct files.\n' ...
                       'Install the Octave development package for your distro:\n' ...
                       '  Fedora/RHEL/AlmaLinux/CentOS: octave-devel\n' ...
                       '  Debian/Ubuntu:                octave-dev (>= Bookworm) or liboctave-dev\n' ...
                       '  Alpine:                       octave-dev']);
            end
            rethrow(e);
        end
    else
        oct_files = {'h5readatt_octave.cc', 'h5writemode_octave.cc'};
        for k = 1:numel(oct_files)
            mkoctfile('-lhdf5', oct_files{k})
        end
    end
else
    disp('Matlab does not need this function. It is Octave only.')
end

cd(current_path);
