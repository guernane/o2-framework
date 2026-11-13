// Copyright 2020-2022 CERN and copyright holders of ALICE O2.
// See https://alice-o2.web.cern.ch/copyright for details of the copyright holders.
// All rights not expressly granted are reserved.
//
// This software is distributed under the terms of the GNU General Public
// License v3 (GPL Version 3), copied verbatim in the file "COPYING".
//
// In applying this license CERN does not waive the privileges and immunities
// granted to it by virtue of its status as an Intergovernmental Organization
// or submit itself to any jurisdiction.

/// \file   taskE2e.cxx
/// \author Rachid Guernane <guernane@lpsc.in2p3.fr>
/// \brief  Diagnostic task: fills histograms for ALL tracks (no filter) plus
///         a "cut flow" telling how many tracks pass each single selection
///         cut of the TrackSelection table, to understand why isGlobalTrack()
///         can reject every track.
///
///         v3: the cut flow reads the bitmask TrackSelection::trackCutFlag()
///         with TrackSelectionFlags::checkFlag(). The per-cut passed*()
///         columns are NOT used: in current O2Physics they live in a separate
///         table (TrackSelectionExtension), only produced on demand, so they
///         are not available through aod::TrackSelection.

#include "Framework/runDataProcessing.h"
#include "Framework/AnalysisTask.h"
#include "Framework/HistogramRegistry.h"
#include "Common/DataModel/TrackSelectionTables.h"
#include "Common/DataModel/EventSelection.h"

#include <string>
#include <utility>
#include <vector>

using namespace o2;
using namespace o2::framework;
using namespace o2::framework::expressions;

using TSF = o2::aod::track::TrackSelectionFlags;

struct E2eTask {

  HistogramRegistry registry{"registry"};

  // (label, mask) pairs. A track "passes" an entry when all bits of its mask
  // are set in trackCutFlag(); mask 0 is always true (= all tracks).
  const std::vector<std::pair<std::string, TSF::flagtype>> cuts{
    {"all tracks", 0},
    // single cuts
    {"TrackType", TSF::kTrackType},
    {"PtRange", TSF::kPtRange},
    {"EtaRange", TSF::kEtaRange},
    {"TPCNCls", TSF::kTPCNCls},
    {"TPCCrossedRows", TSF::kTPCCrossedRows},
    {"TPCCrossedRowsOverNCls", TSF::kTPCCrossedRowsOverNCls},
    {"TPCChi2NDF", TSF::kTPCChi2NDF},
    {"TPCRefit", TSF::kTPCRefit},
    {"ITSNCls", TSF::kITSNCls},
    {"ITSChi2NDF", TSF::kITSChi2NDF},
    {"ITSRefit", TSF::kITSRefit},
    {"ITSHits", TSF::kITSHits},
    {"GoldenChi2", TSF::kGoldenChi2},
    {"DCAxy", TSF::kDCAxy},
    {"DCAz", TSF::kDCAz},
    // combinations
    {"QualityTracks", TSF::kQualityTracks},
    {"PrimaryTracks", TSF::kPrimaryTracks},
    {"InAcceptanceTracks", TSF::kInAcceptanceTracks},
    {"GlobalTrackWoDCA", TSF::kGlobalTrackWoDCA},
    {"GlobalTrack", TSF::kGlobalTrack}};

  static constexpr int kNSingleCuts = 15; // entries 1..15 of 'cuts'

  void init(InitContext&)
  {
    const AxisSpec axPt{200, 0.f, 50.f, "p_{T} (GeV/c)"};
    const AxisSpec axNtr{200, 0.f, 20000.f, "N_{tracks}"}; // 0-200 overflowed for most events
    const AxisSpec axRows{200, 0.f, 200.f, "TPC crossed rows"};
    const AxisSpec axChi2{100, 0.f, 50.f, "ITS chi2/Ncl"};
    const AxisSpec axDcaXY{400, -2.f, 2.f, "DCA_{xy} (cm)"};
    const AxisSpec axDcaZ{400, -10.f, 10.f, "DCA_{z} (cm)"};
    const int nCuts = static_cast<int>(cuts.size());
    const AxisSpec axCut{nCuts, 0.f, static_cast<float>(nCuts), "cut passed"};
    const AxisSpec axNPassed{kNSingleCuts + 1, -0.5f, kNSingleCuts + 0.5f, "number of single cuts passed"};

    registry.add("hEventCounter", "Event counter", {HistType::kTH1F, {{2, 0.f, 2.f}}});
    registry.add("hTrackPt_All", "Track pT (no filter)", {HistType::kTH1F, {axPt}});
    registry.add("hTrackPt_Global", "Track pT (isGlobalTrack)", {HistType::kTH1F, {axPt}});
    registry.add("hNTrackPerEvt_All", "N tracks per event (no filter)", {HistType::kTH1F, {axNtr}});
    registry.add("hNTrackPerEvt_Global", "N tracks per event (isGlobalTrack)", {HistType::kTH1F, {axNtr}});
    registry.add("hTPCCrossedRows", "TPC crossed rows (all tracks)", {HistType::kTH1F, {axRows}});
    registry.add("hITSChi2", "ITS chi2/Ncl (all tracks)", {HistType::kTH1F, {axChi2}});
    registry.add("hDCAxy", "DCA_{xy} (all tracks)", {HistType::kTH1F, {axDcaXY}});
    registry.add("hDCAz", "DCA_{z} (all tracks)", {HistType::kTH1F, {axDcaZ}});
    registry.add("hCutFlow", "Tracks passing each cut (taken alone)", {HistType::kTH1F, {axCut}});
    registry.add("hNCutsPassed", "Single cuts passed per track", {HistType::kTH1F, {axNPassed}});

    auto hCut = registry.get<TH1>(HIST("hCutFlow"));
    for (int i = 0; i < nCuts; ++i) {
      hCut->GetXaxis()->SetBinLabel(i + 1, cuts[i].first.c_str());
    }

    LOG(info) << "E2eTask (diagnostic v3) initialized";
  }

  using MyTracks = soa::Join<aod::Tracks, aod::TracksExtra, aod::TracksDCA, aod::TrackSelection>;

  void process(aod::Collision const& /*collision*/, MyTracks const& tracks)
  {
    registry.fill(HIST("hEventCounter"), 0.5f);

    int nAll = 0;
    int nGlobal = 0;
    for (auto const& track : tracks) {
      registry.fill(HIST("hTrackPt_All"), track.pt());
      registry.fill(HIST("hTPCCrossedRows"), track.tpcNClsCrossedRows());
      registry.fill(HIST("hITSChi2"), track.itsChi2NCl());
      registry.fill(HIST("hDCAxy"), track.dcaXY());
      registry.fill(HIST("hDCAz"), track.dcaZ());
      ++nAll;

      const TSF::flagtype flags = track.trackCutFlag();
      int nPassed = 0;
      for (int i = 0; i < static_cast<int>(cuts.size()); ++i) {
        if (TSF::checkFlag(flags, cuts[i].second)) {
          registry.fill(HIST("hCutFlow"), i + 0.5f);
          if (i >= 1 && i <= kNSingleCuts) {
            ++nPassed;
          }
        }
      }
      registry.fill(HIST("hNCutsPassed"), static_cast<float>(nPassed));

      if (track.isGlobalTrack()) {
        registry.fill(HIST("hTrackPt_Global"), track.pt());
        ++nGlobal;
      }
    }
    registry.fill(HIST("hNTrackPerEvt_All"), static_cast<float>(nAll));
    registry.fill(HIST("hNTrackPerEvt_Global"), static_cast<float>(nGlobal));
  }
};

WorkflowSpec defineDataProcessing(ConfigContext const& cfgc)
{
  return WorkflowSpec{adaptAnalysisTask<E2eTask>(cfgc)};
}
