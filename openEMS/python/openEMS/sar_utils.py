# -*- coding: utf-8 -*-

import numpy as np

def readSAR(fn, f_idx=0):
    """Read a SAR result HDF5 file written by SAR_Calculation.

    Parameters
    ----------
    fn : str
        Path to the SAR result HDF5 file.
    f_idx : int, optional
        Frequency index to read (default 0).

    Returns
    -------
    sar : ndarray, shape (nx, ny, nz)
        SAR values in W/kg.
    mesh : list of three 1-D ndarrays
        Mesh node coordinates [x, y, z].
    sar_data : dict
        Metadata from the file: 'mass' (kg), 'frequency' (Hz), 'power' (W),
        and any other dataset attributes (e.g. 'maxSAR').
    Returns (None, None, None) if the file does not contain a recognised
    openEMS HDF5 version attribute.
    """
    sar_data = {}
    import h5py
    with h5py.File(fn, 'r') as h5:
        if 'openEMS_HDF5_version' in h5.attrs:
            sar = h5['/FieldData/FD/f{}'.format(f_idx)]
            sar_data['mass'] = h5.attrs['mass']
            sar_data.update(sar.attrs)
            sar = np.array(sar)
            if h5.attrs['openEMS_HDF5_version'] <= 0.2:
                sar = sar.swapaxes(0,2)
            mesh = [None, None, None]
            for n, d in enumerate('xyz'):
                mesh[n] = np.array(h5['Mesh/'+d])
            return sar, mesh, sar_data

    return None, None, None
