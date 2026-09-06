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

#include "CSSpatialIndex.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <limits>

#include "CSPrimitives.h"

namespace
{
static std::atomic<unsigned long> g_Generation{1};
}

unsigned long CSSpatialIndex_BumpGeneration()
{
	return g_Generation.fetch_add(1, std::memory_order_relaxed) + 1;
}

unsigned long CSSpatialIndex_CurrentGeneration()
{
	return g_Generation.load(std::memory_order_relaxed);
}

void CSSpatialIndex::Build(const std::vector<CSProperties*>& properties, double tol)
{
	double pad = std::abs(tol);
	m_UnboundedEntries.clear();
	m_BoundedEntries.clear();
	m_Cells.clear();
	m_Empty = true;

	struct BoundedInfo
	{
		double bb[6];
	};
	std::vector<BoundedInfo> boundedInfo;

	double min[3] = {std::numeric_limits<double>::max(), std::numeric_limits<double>::max(),
	                  std::numeric_limits<double>::max()};
	double max[3] = {-std::numeric_limits<double>::max(), -std::numeric_limits<double>::max(),
	                  -std::numeric_limits<double>::max()};

	std::size_t seq = 0;
	for (CSProperties* prop : properties)
	{
		if (prop == nullptr)
			continue;
		std::size_t qty = prop->GetQtyPrimitives();
		for (std::size_t i = 0; i < qty; ++i)
		{
			CSPrimitives* prim = prop->GetPrimitive(i);
			if (prim == nullptr)
				continue;
			Entry e{prop, prim, seq++};

			// GetBoundBox()'s bool return means "orientation-accurate" (e.g. CSPrimPolygon and
			// CSPrimLinPoly -- which is exactly what every Gerber copper/via/NPTH primitive this
			// project creates actually is -- always return false here, regardless of whether the
			// array itself is valid; CSPrimBox similarly returns false only for a coordinate-system
			// mismatch, again after already filling the array). Treating that return value as "no
			// usable bounding box" silently routed every polygon-shaped primitive into
			// m_UnboundedEntries -- still correct (that list is always fully scanned, same as the
			// original linear scan), but defeats the whole point of this index for the dominant
			// primitive type on a real board. NaN-seed the array instead and judge validity purely
			// by isfinite(): a primitive type that doesn't override GetBoundBox() at all (the
			// CSPrimitives base default leaves the array untouched) still correctly falls back to
			// unbounded, since it never overwrites the seeded NaNs.
			double bb[6] = {std::numeric_limits<double>::quiet_NaN(), std::numeric_limits<double>::quiet_NaN(),
			                 std::numeric_limits<double>::quiet_NaN(), std::numeric_limits<double>::quiet_NaN(),
			                 std::numeric_limits<double>::quiet_NaN(), std::numeric_limits<double>::quiet_NaN()};
			prim->GetBoundBox(bb);
			bool ok = true;
			for (int d = 0; d < 6; ++d)
				ok = ok && std::isfinite(bb[d]);
			if (!ok)
			{
				m_UnboundedEntries.push_back(e);
				continue;
			}

			// GetBoundBox() does not guarantee bb[2d] <= bb[2d+1] -- e.g. CSPrimBox::GetBoundBox()
			// stores its raw start/stop coordinates per axis unordered, and consumers legitimately
			// construct boxes with start > stop on an axis (kicad_ems's own substrate layers do
			// this for Z). Normalize per-axis before using these as a min/max pair, or an inverted
			// axis silently produces an empty (lo>hi) cell range below and the primitive never gets
			// indexed at all.
			double bbMin[3] = {std::min(bb[0], bb[1]), std::min(bb[2], bb[3]), std::min(bb[4], bb[5])};
			double bbMax[3] = {std::max(bb[0], bb[1]), std::max(bb[2], bb[3]), std::max(bb[4], bb[5])};

			m_BoundedEntries.push_back(e);
			boundedInfo.push_back({{bbMin[0] - pad, bbMax[0] + pad, bbMin[1] - pad, bbMax[1] + pad,
			                         bbMin[2] - pad, bbMax[2] + pad}});
			for (int d = 0; d < 3; ++d)
			{
				min[d] = std::min(min[d], bbMin[d] - pad);
				max[d] = std::max(max[d], bbMax[d] + pad);
			}
		}
	}

	if (m_BoundedEntries.empty())
	{
		// still valid: every query just falls back to the (small/empty) unbounded list
		return;
	}

	for (int d = 0; d < 3; ++d)
	{
		m_Min[d] = min[d];
		m_Max[d] = max[d];
	}

	// aim for a handful of bounded entries per cell on average
	const double targetPerCell = 4.0;
	double totalCells = std::max(1.0, static_cast<double>(m_BoundedEntries.size()) / targetPerCell);
	double extents[3];
	double domainVolume = 1.0;
	for (int d = 0; d < 3; ++d)
	{
		extents[d] = std::max(0.0, m_Max[d] - m_Min[d]);
		domainVolume *= std::max(extents[d], 1e-12);
	}
	double cellsPerAxisScale = std::cbrt(totalCells);

	for (int d = 0; d < 3; ++d)
	{
		if (extents[d] <= 0.0)
		{
			m_Dims[d] = 1;
			m_CellSize[d] = 1.0;
			continue;
		}
		int dim = static_cast<int>(std::round(cellsPerAxisScale));
		dim = std::max(1, std::min(dim, 128));
		m_Dims[d] = dim;
		m_CellSize[d] = extents[d] / dim;
	}

	m_Cells.resize(static_cast<std::size_t>(m_Dims[0]) * m_Dims[1] * m_Dims[2]);

	for (std::size_t idx = 0; idx < m_BoundedEntries.size(); ++idx)
	{
		const double* bb = boundedInfo[idx].bb;
		int lo[3], hi[3];
		for (int d = 0; d < 3; ++d)
		{
			if (m_CellSize[d] <= 0.0)
			{
				lo[d] = hi[d] = 0;
				continue;
			}
			lo[d] = static_cast<int>(std::floor((bb[2 * d] - m_Min[d]) / m_CellSize[d]));
			hi[d] = static_cast<int>(std::floor((bb[2 * d + 1] - m_Min[d]) / m_CellSize[d]));
			lo[d] = std::max(0, std::min(lo[d], m_Dims[d] - 1));
			hi[d] = std::max(0, std::min(hi[d], m_Dims[d] - 1));
		}
		for (int z = lo[2]; z <= hi[2]; ++z)
			for (int y = lo[1]; y <= hi[1]; ++y)
				for (int x = lo[0]; x <= hi[0]; ++x)
				{
					int cell[3] = {x, y, z};
					m_Cells[FlatIndex(cell)].push_back(idx);
				}
	}

	m_Empty = false;
}

bool CSSpatialIndex::InDomain(const double* coord) const
{
	for (int d = 0; d < 3; ++d)
		if (coord[d] < m_Min[d] || coord[d] > m_Max[d])
			return false;
	return true;
}

void CSSpatialIndex::CellCoordsClamped(const double* coord, int cellIdx[3]) const
{
	for (int d = 0; d < 3; ++d)
	{
		if (m_CellSize[d] <= 0.0)
		{
			cellIdx[d] = 0;
			continue;
		}
		int c = static_cast<int>(std::floor((coord[d] - m_Min[d]) / m_CellSize[d]));
		cellIdx[d] = std::max(0, std::min(c, m_Dims[d] - 1));
	}
}

std::size_t CSSpatialIndex::FlatIndex(const int cellIdx[3]) const
{
	return (static_cast<std::size_t>(cellIdx[2]) * m_Dims[1] + cellIdx[1]) *
	           static_cast<std::size_t>(m_Dims[0]) +
	       cellIdx[0];
}

std::vector<CSSpatialIndex::Entry> CSSpatialIndex::CandidatesAt(const double* coord) const
{
	std::vector<Entry> result = m_UnboundedEntries;

	if (!m_Empty && InDomain(coord))
	{
		int cellIdx[3];
		CellCoordsClamped(coord, cellIdx);
		const std::vector<std::size_t>& cell = m_Cells[FlatIndex(cellIdx)];
		result.reserve(result.size() + cell.size());
		for (std::size_t idx : cell)
			result.push_back(m_BoundedEntries[idx]);
	}

	std::sort(result.begin(), result.end(),
	          [](const Entry& a, const Entry& b) { return a.seq < b.seq; });
	return result;
}

CSProperties* CSSpatialIndex::Query(const double* coord, CSProperties::PropertyType type,
                                     bool markFoundAsUsed, CSPrimitives** foundPrimitive,
                                     double tol) const
{
	std::vector<Entry> candidates = CandidatesAt(coord);

	CSProperties* winProp = nullptr;
	CSPrimitives* winPrim = nullptr;
	int winPrio = 0;

	std::size_t i = 0;
	while (i < candidates.size())
	{
		CSProperties* curProp = candidates[i].prop;
		std::size_t j = i;

		bool typeMatches = (type == CSProperties::ANY) || (curProp->GetType() & type);

		CSPrimitives* locPrim = nullptr;
		int locPrio = 0;
		bool found = false;
		if (typeMatches)
		{
			// replicate CSProperties::CheckCoordInPrimitive() exactly, restricted to this
			// property's own candidates (contiguous in `candidates` since it's sorted by the
			// original property-major traversal order).
			while (j < candidates.size() && candidates[j].prop == curProp)
			{
				CSPrimitives* prim = candidates[j].prim;
				if (prim->IsInside(coord, tol))
				{
					if (!found)
					{
						locPrio = prim->GetPriority() - 1;
						locPrim = prim;
					}
					found = true;
					if (prim->GetPriority() > locPrio)
					{
						locPrio = prim->GetPriority();
						locPrim = prim;
					}
				}
				++j;
			}
		}
		else
		{
			while (j < candidates.size() && candidates[j].prop == curProp)
				++j;
		}

		if (locPrim)
		{
			if (winProp == nullptr)
			{
				winPrio = locPrio;
				winProp = curProp;
				winPrim = locPrim;
			}
			else if (locPrio > winPrio)
			{
				winPrio = locPrio;
				winProp = curProp;
				winPrim = locPrim;
			}
		}

		i = j;
	}

	if (markFoundAsUsed && winPrim)
		winPrim->SetPrimitiveUsed(true);
	if (foundPrimitive)
		*foundPrimitive = winPrim;
	return winProp;
}
