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
// taskTemplate.cxx
// Minimal starter analysis task — copy this to bootstrap a new analysis.
//
// How to use:
//   1. Copy this directory: cp -r analysis/template analysis/<myAnalysis>
//   2. Rename this file and the struct/binary names below to something
//      specific to your analysis (do NOT leave "Template"/"template" in
//      the final task — every binary must have a unique DPL name).
//   3. Add an entry for it in analysis/<myAnalysis>/analysis.json.
//
// How to place the renamed file in your O2Physics fork:
//   cp analysis/<myAnalysis>/code/Tasks/<yourTask>.cxx \
//      ~/alice/sw/O2Physics/PWGJE/Tasks/
//
// Add to ~/alice/sw/O2Physics/PWGJE/Tasks/CMakeLists.txt:
//   o2physics_add_dpl_workflow(<your-dpl-name>
//       SOURCES <yourTask>.cxx
//       PUBLIC_LINK_LIBRARIES O2Physics::AnalysisCore
//       COMPONENT_NAME Analysis)
//
// Rebuild:
//   o2 build --rebuild-tasks
//
// Activate: enable the analysis in analysis.json
//   (o2 analysis --enable <myAnalysis>)
//
// Reference:
//   https://aliceo2group.github.io/analysis-framework/docs/basics-tasks/
// ==============================================================================

#include "Framework/AnalysisTask.h"
#include "Framework/AnalysisDataModel.h"
#include "Framework/runDataProcessing.h"
#include "Framework/HistogramRegistry.h"

#include "Common/DataModel/EventSelection.h"

using namespace o2;
using namespace o2::framework;
using namespace o2::framework::expressions;

// ==============================================================================
// Rename this struct to match your task
// ==============================================================================
struct MyAnalysisTask {

  // --------------------------------------------------------------------------
  // Configurables — settable from dpl-config.json without recompiling
  // --------------------------------------------------------------------------
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
    registry.add("hEventCounter",
                 "Event counter;;Counts",
                 {HistType::kTH1F, {{2, 0., 2.}}});
    auto h = registry.get<TH1>(HIST("hEventCounter"));
    h->GetXaxis()->SetBinLabel(1, "All");
    h->GetXaxis()->SetBinLabel(2, "sel8");

    registry.add("hTrackPt",
                 "Track p_{T};p_{T} (GeV/c);Counts",
                 {HistType::kTH1F, {{200, 0., 20.}}});
  }

  // --------------------------------------------------------------------------
  // Type aliases
  // --------------------------------------------------------------------------
  using SelectedCollisions = soa::Join<aod::Collisions, aod::EvSels>;

  // --------------------------------------------------------------------------
  // process: called for each collision
  // --------------------------------------------------------------------------
  void process(SelectedCollisions::iterator const& collision,
               aod::Tracks const& tracks)
  {
    registry.fill(HIST("hEventCounter"), 0.5); // All

    if (!collision.sel8()) {
      return;
    }
    registry.fill(HIST("hEventCounter"), 1.5); // sel8

    for (auto const& track : tracks) {
      if (track.pt() < static_cast<float>(trackPtMin)) continue;
      registry.fill(HIST("hTrackPt"), track.pt());
    }
  }

}; // struct MyAnalysisTask

// ==============================================================================
// Workflow definition — rename the DPL name and struct to match your task
// ==============================================================================
WorkflowSpec defineDataProcessing(ConfigContext const& cfgc)
{
  return WorkflowSpec{
    adaptAnalysisTask<MyAnalysisTask>(cfgc)
  };
}
