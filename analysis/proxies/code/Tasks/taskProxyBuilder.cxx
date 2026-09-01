// Copyright 2020-2022 CERN and copyright holders of ALICE O2.
// See https://alice-o2.cern.ch/copyright for details of the copyright holders.
// All rights not expressly granted are reserved.
//
// This software is distributed under the terms of the GNU General Public
// License v3 (GPL Version 3), copied verbatim in the file "COPYING".
//
// In applying this license CERN does not waive the privileges and immunities
// granted to it by virtue of its status as an Intergovernmental Organization
// or submit itself to any jurisdiction.

// ==============================================================================
// taskProxyBuilder.cxx
// Starter analysis task for b-jet proxy studies — PWGJE.
//
// What this task does:
//   - subscribes to charged jets (o2-analysis-je-jet-finder-charged)
//   - subscribes to quality-selected tracks (o2-analysis-trackselection)
//   - fills jet and track QA histograms
//
// How to place this file in your O2Physics fork:
//   cp analyses/proxies/code/Tasks/taskProxyBuilder.cxx \
//      ~/alice/sw/O2Physics/PWGJE/Tasks/
//
// Add to ~/alice/sw/O2Physics/PWGJE/Tasks/CMakeLists.txt:
//   o2physics_add_dpl_workflow(je-proxy-builder
//       SOURCES taskProxyBuilder.cxx
//       PUBLIC_LINK_LIBRARIES O2Physics::PWGJECore
//       COMPONENT_NAME Analysis)
//
// Rebuild:
//   o2 build --rebuild-tasks
//
// Activate in config_tasks.sh:
//   DOO2_USER_PROXY_BUILDER=1
//
// Binary produced: o2-analysis-je-proxy-builder
//
// Reference:
//   https://aliceo2group.github.io/analysis-framework/docs/basics-tasks/
// ==============================================================================

#include "Framework/AnalysisTask.h"
#include "Framework/AnalysisDataModel.h"
#include "Framework/ASoAHelpers.h"
#include "Framework/runDataProcessing.h"
#include "Framework/HistogramRegistry.h"

#include "Common/DataModel/EventSelection.h"
#include "Common/DataModel/TrackSelectionTables.h"

#include "PWGJE/DataModel/Jet.h"

using namespace o2;
using namespace o2::framework;
using namespace o2::framework::expressions;

// ==============================================================================
// Proxy builder task struct
// ==============================================================================
struct ProxyBuilderTask {

  // --------------------------------------------------------------------------
  // Configurables — settable from dpl-config.json without recompiling
  // --------------------------------------------------------------------------
  Configurable<float> jetPtMin{"jetPtMin",   5.0f, "Minimum jet pT (GeV/c)"};
  Configurable<float> jetEtaMax{"jetEtaMax", 0.5f, "Maximum |eta| for jets"};
  Configurable<float> trackPtMin{"trackPtMin", 0.1f, "Minimum track pT (GeV/c)"};

  // --------------------------------------------------------------------------
  // Histogram registry
  // OutputObjHandlingPolicy::AnalysisObject → AnalysisResults.root
  // --------------------------------------------------------------------------
  HistogramRegistry registry{
    "registry",
    {},
    OutputObjHandlingPolicy::AnalysisObject,
    true,   // sortHistos
    true    // createRegistryDir
  };

  // --------------------------------------------------------------------------
  // init: define histograms — called once at startup
  // --------------------------------------------------------------------------
  void init(InitContext const&)
  {
    // Event counter
    registry.add("hEventCounter",
                 "Event counter;;Counts",
                 {HistType::kTH1F, {{3, 0., 3.}}});
    auto h = registry.get<TH1>(HIST("hEventCounter"));
    h->GetXaxis()->SetBinLabel(1, "All");
    h->GetXaxis()->SetBinLabel(2, "sel8");
    h->GetXaxis()->SetBinLabel(3, "Has jets");

    // Track histograms
    registry.add("hTrackPt",
                 "Track p_{T};p_{T} (GeV/c);Counts",
                 {HistType::kTH1F, {{200, 0., 20.}}});
    registry.add("hTrackEta",
                 "Track #eta;#eta;Counts",
                 {HistType::kTH1F, {{100, -1., 1.}}});
    registry.add("hTrackPhi",
                 "Track #phi;#phi (rad);Counts",
                 {HistType::kTH1F, {{100, 0., 2. * M_PI}}});

    // Jet histograms
    registry.add("hJetPt",
                 "Jet p_{T};p_{T} (GeV/c);Counts",
                 {HistType::kTH1F, {{200, 0., 200.}}});
    registry.add("hJetEta",
                 "Jet #eta;#eta;Counts",
                 {HistType::kTH1F, {{100, -1., 1.}}});
    registry.add("hJetPhi",
                 "Jet #phi;#phi (rad);Counts",
                 {HistType::kTH1F, {{100, 0., 2. * M_PI}}});
    registry.add("hJetNTracks",
                 "Tracks per jet;N_{tracks};Counts",
                 {HistType::kTH1F, {{50, 0., 50.}}});
    registry.add("hJetArea",
                 "Jet area;Area;Counts",
                 {HistType::kTH1F, {{100, 0., 2.}}});
  }

  // --------------------------------------------------------------------------
  // Type aliases
  // --------------------------------------------------------------------------
  using SelectedCollisions = soa::Join<aod::Collisions, aod::EvSels>;
  using TracksWithSelection = soa::Join<aod::Tracks, aod::TrackSelection>;
  using ChargedJets = aod::ChargedJets;

  // --------------------------------------------------------------------------
  // process: called for each collision
  // --------------------------------------------------------------------------
  void process(SelectedCollisions::iterator const& collision,
               ChargedJets const& jets,
               TracksWithSelection const& tracks)
  {
    registry.fill(HIST("hEventCounter"), 0.5); // All

    if (!collision.sel8()) {
      return;
    }
    registry.fill(HIST("hEventCounter"), 1.5); // sel8

    // Track loop
    for (auto const& track : tracks) {
      if (!track.isGlobalTrack()) continue;
      if (track.pt() < static_cast<float>(trackPtMin)) continue;
      registry.fill(HIST("hTrackPt"),  track.pt());
      registry.fill(HIST("hTrackEta"), track.eta());
      registry.fill(HIST("hTrackPhi"), track.phi());
    }

    // Jet loop
    bool hasJets = false;
    for (auto const& jet : jets) {
      if (jet.pt()             < static_cast<float>(jetPtMin))  continue;
      if (std::abs(jet.eta())  > static_cast<float>(jetEtaMax)) continue;
      hasJets = true;
      registry.fill(HIST("hJetPt"),      jet.pt());
      registry.fill(HIST("hJetEta"),     jet.eta());
      registry.fill(HIST("hJetPhi"),     jet.phi());
      registry.fill(HIST("hJetNTracks"), jet.tracksIds().size());
      registry.fill(HIST("hJetArea"),    jet.area());
    }

    if (hasJets) {
      registry.fill(HIST("hEventCounter"), 2.5); // Has jets
    }
  }

}; // struct ProxyBuilderTask

// ==============================================================================
// Workflow definition
// Binary name: o2-analysis-je-proxy-builder
// ==============================================================================
WorkflowSpec defineDataProcessing(ConfigContext const& cfgc)
{
  return WorkflowSpec{
    adaptAnalysisTask<ProxyBuilderTask>(cfgc)
  };
}
