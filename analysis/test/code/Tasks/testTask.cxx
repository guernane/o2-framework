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

/// \file   testTask.cxx
/// \author Rachid Guernane <guernane@lpsc.in2p3.fr>
/// \brief  Diagnostic version: fills histograms for ALL tracks (no filter)
///         plus a separate counter for tracks passing isGlobalTrack(),
///         to understand whether the track selection is really rejecting
///         everything or whether there's an upstream problem.

#include "Framework/runDataProcessing.h"
#include "Framework/AnalysisTask.h"
#include "Framework/HistogramRegistry.h"
#include "Common/DataModel/TrackSelectionTables.h"
#include "Common/DataModel/EventSelection.h"

using namespace o2;
using namespace o2::framework;
using namespace o2::framework::expressions;

struct TestTask {

  HistogramRegistry registry{"registry"};

  void init(InitContext&)
  {
    const AxisSpec axPt  {200,  0.f,  50.f, "p_{T} (GeV/c)"};
    const AxisSpec axEta {200, -1.f,   1.f, "eta"};
    const AxisSpec axNtr {200,  0.f, 200.f, "N_{tracks}"};
    const AxisSpec axRows {200, 0.f, 200.f, "TPC crossed rows"};
    const AxisSpec axChi2 {100, 0.f, 50.f, "ITS chi2/Ncl"};

    registry.add("hEventCounter",     "Event counter",       {HistType::kTH1F, {{2, 0.f, 2.f}}});
    registry.add("hTrackPt_All",      "Track pT (no filter)", {HistType::kTH1F, {axPt}});
    registry.add("hTrackPt_Global",   "Track pT (isGlobalTrack)", {HistType::kTH1F, {axPt}});
    registry.add("hNTrackPerEvt_All", "N tracks per event (no filter)", {HistType::kTH1F, {axNtr}});
    registry.add("hNTrackPerEvt_Global", "N tracks per event (isGlobalTrack)", {HistType::kTH1F, {axNtr}});
    registry.add("hTPCCrossedRows",   "TPC crossed rows (all tracks)", {HistType::kTH1F, {axRows}});
    registry.add("hITSChi2",         "ITS chi2/Ncl (all tracks)", {HistType::kTH1F, {axChi2}});

    LOG(info) << "TestTask (diagnostic) initialized";
  }

  using MyTracks = soa::Join<aod::Tracks, aod::TracksExtra, aod::TrackSelection>;

  void process(aod::Collision const& /*collision*/, MyTracks const& tracks)
  {
    registry.fill(HIST("hEventCounter"), 0.5f);

    int nAll = 0;
    int nGlobal = 0;
    for (auto const& track : tracks) {
      registry.fill(HIST("hTrackPt_All"), track.pt());
      registry.fill(HIST("hTPCCrossedRows"), track.tpcNClsCrossedRows());
      registry.fill(HIST("hITSChi2"), track.itsChi2NCl());
      ++nAll;

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
  return WorkflowSpec{adaptAnalysisTask<TestTask>(cfgc)};
}
