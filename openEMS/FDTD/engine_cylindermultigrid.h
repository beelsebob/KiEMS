/*
*	Copyright (C) 2010 Thorsten Liebig (Thorsten.Liebig@gmx.de)
*
*	This program is free software: you can redistribute it and/or modify
*	it under the terms of the GNU General Public License as published by
*	the Free Software Foundation, either version 3 of the License, or
*	(at your option) any later version.
*
*	This program is distributed in the hope that it will be useful,
*	but WITHOUT ANY WARRANTY; without even the implied warranty of
*	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
*	GNU General Public License for more details.
*
*	You should have received a copy of the GNU General Public License
*	along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

#ifndef ENGINE_CYLINDERMULTIGRID_H
#define ENGINE_CYLINDERMULTIGRID_H

#include "engine_cylinder.h"

#include <barrier>
#include <thread>
#include <vector>

class Operator_CylinderMultiGrid;
class Engine_CylinderMultiGrid_Thread;
class Engine_Ext_CylinderMultiGrid;

class Engine_CylinderMultiGrid : public Engine_Cylinder
{
	friend class Engine_Ext_CylinderMultiGrid;
public:
//	Engine_CylinderMultiGrid();

	static Engine_CylinderMultiGrid* New(const Operator_CylinderMultiGrid* op, unsigned int numThreads = 0);
	virtual ~Engine_CylinderMultiGrid();

	virtual void InterpolVoltChild2Base(unsigned int rPos);
	virtual void InterpolCurrChild2Base(unsigned int rPos);

	virtual void Init();

	//! Iterate \a iterTS number of timesteps
	virtual bool IterateTS(unsigned int iterTS);

protected:
	Engine_CylinderMultiGrid(const Operator_CylinderMultiGrid* op);
	const Operator_CylinderMultiGrid* Op_CMG;

	Engine_Multithread* m_InnerEngine;

	unsigned int m_Thread_NumTS;
	std::vector<std::jthread> m_iteratorThreads;
	std::barrier<> *m_startBarrier;
	std::barrier<> *m_stopBarrier;

	//extension barrier
	std::barrier<> *m_WaitOnBase;
	std::barrier<> *m_WaitOnChild;
	std::barrier<> *m_WaitOnSync;

	Engine_Ext_CylinderMultiGrid* m_Eng_Ext_MG;

#ifdef MPI_SUPPORT
	virtual void SendReceiveVoltages();
	virtual void SendReceiveCurrents();
#endif
};


class Engine_CylinderMultiGrid_Thread
{
public:
	Engine_CylinderMultiGrid_Thread( Engine_Multithread* engine, std::barrier<> *start, std::barrier<> *stop, unsigned int* numTS, bool isBase);
	void operator()();

protected:
	Engine_Multithread *m_Eng;
	bool m_isBase;
	std::barrier<> *m_startBarrier;
	std::barrier<> *m_stopBarrier;
	unsigned int *m_numTS;
};

#endif // ENGINE_CYLINDERMULTIGRID_H
