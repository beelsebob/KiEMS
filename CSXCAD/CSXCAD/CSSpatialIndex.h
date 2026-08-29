/*
*	Copyright (C) 2008-2025 Thorsten Liebig (Thorsten.Liebig@gmx.de)
*
*	This program is free software: you can redistribute it and/or modify
*	it under the terms of the GNU Lesser General Public License as published
*	by the Free Software Foundation, either version 3 of the License, or
*	(at your option) any later version.
*
*	This program is distributed in the hope that it will be useful,
*	but WITHOUT ANY WARRANTY; without even the implied warranty of
*	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
*	GNU Lesser General Public License for more details.
*
*	You should have received a copy of the GNU Lesser General Public License
*	along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

#pragma once

#include <cstddef>
#include <vector>

#include "CSProperties.h"

class CSPrimitives;

//! Uniform-grid spatial index accelerating ContinuousStructure::GetPropertyByCoordPriority(), which
//! otherwise does an unaccelerated linear scan over every primitive of every property for every query
//! coordinate. Bucket primitives by their own GetBoundBox() into a uniform 3D grid; Query() only
//! evaluates the (small) candidate set relevant to the query cell, via the exact same per-property,
//! priority-ordered IsInside() resolution the original linear scan did -- identical results, far
//! fewer IsInside() calls per query once primitive counts get large relative to how localized any one
//! query coordinate's true candidates are.
class CSSpatialIndex
{
public:
	//! Rebuild from every primitive of every property in `properties` (in order -- must match
	//! ContinuousStructure::vProperties, since query-time priority tie-breaking depends on
	//! reproducing that traversal order exactly). `tol` is the drawing tolerance IsInside() gets
	//! called with at query time (ContinuousStructure's own dDrawingTol) -- bounding boxes are
	//! padded by it so a primitive whose exact bbox narrowly misses a cell, but whose
	//! tolerance-widened IsInside() would still match, doesn't get missed.
	void Build(const std::vector<CSProperties*>& properties, double tol);

	//! Equivalent to ContinuousStructure::GetPropertyByCoordPriority()'s original linear-scan body,
	//! restricted to this index's own candidate set for `coord`.
	CSProperties* Query(const double* coord, CSProperties::PropertyType type, bool markFoundAsUsed,
	                     CSPrimitives** foundPrimitive, double tol) const;

private:
	struct Entry
	{
		CSProperties* prop;
		CSPrimitives* prim;
		std::size_t seq; //!< global position in the property-major, then-primitive-original traversal
	};

	//! Primitives with no usable GetBoundBox() -- checked at every query, matching the original
	//! unaccelerated behavior for that (normally small) subset.
	std::vector<Entry> m_UnboundedEntries;
	//! Primitives with a usable GetBoundBox(), in the same order they were discovered during Build().
	std::vector<Entry> m_BoundedEntries;
	//! Grid cells; each holds indices into m_BoundedEntries.
	std::vector<std::vector<std::size_t>> m_Cells;

	double m_Min[3] = {0, 0, 0};
	double m_Max[3] = {0, 0, 0};
	double m_CellSize[3] = {1, 1, 1};
	int m_Dims[3] = {1, 1, 1};
	bool m_Empty = true;

	void CellCoordsClamped(const double* coord, int cellIdx[3]) const;
	std::size_t FlatIndex(const int cellIdx[3]) const;
	bool InDomain(const double* coord) const;

	//! Gather every candidate entry relevant to `coord` (its own grid cell plus the unbounded
	//! fallback list), merged back into the original global traversal order.
	std::vector<Entry> CandidatesAt(const double* coord) const;
};

//! Process-wide counter, incremented on every geometry-mutating call (ContinuousStructure::
//! AddProperty/RemoveProperty/DeleteProperty and CSProperties::AddPrimitive/RemovePrimitive/
//! DeletePrimitive/TakePrimitive) across every instance. Each ContinuousStructure caches the
//! generation its own CSSpatialIndex was last built at and rebuilds lazily when this no longer
//! matches -- avoids needing a back-pointer from CSProperties to whichever ContinuousStructure
//! owns it (primitives are added to a property after the property itself was already registered).
unsigned long CSSpatialIndex_BumpGeneration();
unsigned long CSSpatialIndex_CurrentGeneration();
