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

#ifndef PROCESSMODEMATCH_H
#define PROCESSMODEMATCH_H

#include "processintegral.h"
#include "CSModeData.h"
#include "../tools/arraylib/array_ijk.h"

class CSFunctionParser;

//! Processing class to match a mode to a given analytic function and return the integral value.
/*!
  The analytric function has to be defined in drawing units.
  It will return the integral value and the mode purity as a secondary value.
  */
class ProcessModeMatch : public ProcessIntegral
{
public:
	ProcessModeMatch(Engine_Interface_Base* eng_if);
	virtual ~ProcessModeMatch();

	virtual std::string GetProcessingName() const;

	virtual std::string GetIntegralName(int row) const;

	virtual void InitProcess();
	virtual void Reset();

	//! Set the field type (0 electric field, 1 magnetic field)
	void SetFieldType(int type);
	//! Set the weight function in the given direction ny. For example: SetWeightFunction(0,"cos(pi/1000*x)*sin(pi/500*y)");
	void SetWeightFunction(int ny, std::string function);

	void SetWeightFile(std::string fileName);
	std::string GetWeightFile() {return m_WeightFile;};

	//! Set the weight origin as a \b Cartesian point (drawing units), for any mesh type.
	//! Coordinates are converted to Cartesian, shifted by this offset, and only then are
	//! x/y/z/rho/a/r/t derived, so that rho and a are measured from this point.
	//! On a cylindrical mesh pass [0,0,z] to keep the mode centered on the mesh axis.
	void SetWeightOrigin(double x, double y, double z) { m_WeightOrigin[0]=x; m_WeightOrigin[1]=y; m_WeightOrigin[2]=z; }

	virtual int GetNumberOfIntegrals() const {return 2;}
	virtual double* CalcMultipleIntegrals();

protected:
	//normal direction of the mode plane
	int m_ny;

	int m_ModeFieldType;

	double GetField(int ny, const unsigned int pos[3]);
	double GetEField(int ny, const unsigned int pos[3]);
	double GetHField(int ny, const unsigned int pos[3]);

	std::string m_WeightFunction[3];
	CSFunctionParser* m_ModeParser[2];

	std::string m_WeightFile;
	double m_WeightOrigin[3];

	unsigned int m_numLines[2];
	ArrayLib::ArrayIJK<double> m_ModeDist;
};

#endif // PROCESSMODEMATCH_H
