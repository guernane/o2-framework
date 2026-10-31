// cutflow.C
// Prints the bin contents of hCutFlow and hNCutsPassed (taskE2e v3) and, for a
// few key histograms: entries, underflow, in-axis integral, overflow and mean.
// Complements dump_hists.C, which only gives the total number of entries.
//
// Usage (from the directory holding the file):
//   root.exe -b -q '/path/to/cutflow.C("AnalysisResults.root")'
//   root.exe -b -q '/path/to/cutflow.C("AnalysisResults.root", "e2e-task")'
//
// Not tested in Claude's environment (no ROOT available there).

#include "TAxis.h"
#include "TFile.h"
#include "TH1.h"
#include "TString.h"
#include <cstdio>

static void stats(TFile* f, const char* task, const char* name)
{
  TH1* h = (TH1*)f->Get(Form("%s/%s", task, name));
  if (!h) {
    printf("  %-22s missing\n", name);
    return;
  }
  const int n = h->GetNbinsX();
  const double under = h->GetBinContent(0);
  const double over = h->GetBinContent(n + 1);
  printf("  %-22s entries=%12.0f  underflow=%12.0f  in-axis=%12.0f  overflow=%12.0f  mean=%10.4g\n",
         name, h->GetEntries(), under, h->Integral(), over, h->GetMean());
}

void cutflow(const char* fileName = "AnalysisResults.root", const char* task = "e2e-task")
{
  TFile* f = TFile::Open(fileName);
  if (!f || f->IsZombie()) {
    printf("Cannot open %s\n", fileName);
    return;
  }

  TH1* cut = (TH1*)f->Get(Form("%s/hCutFlow", task));
  if (cut) {
    const double all = cut->GetBinContent(1);
    printf("\n%-28s %14s %9s\n", "cut (taken alone)", "tracks", "fraction");
    for (int i = 1; i <= cut->GetNbinsX(); ++i) {
      printf("%-28s %14.0f %8.2f%%\n", cut->GetXaxis()->GetBinLabel(i), cut->GetBinContent(i),
             all > 0 ? 100. * cut->GetBinContent(i) / all : 0.);
    }
  } else {
    printf("hCutFlow not found in %s/ (task v2 or older?)\n", task);
  }

  TH1* np = (TH1*)f->Get(Form("%s/hNCutsPassed", task));
  if (np) {
    const double tot = np->Integral();
    printf("\nNumber of single cuts passed per track (0..15):\n");
    for (int i = 1; i <= np->GetNbinsX(); ++i) {
      printf("  %2d : %12.0f  (%5.2f%%)\n", i - 1, np->GetBinContent(i),
             tot > 0 ? 100. * np->GetBinContent(i) / tot : 0.);
    }
  }

  printf("\nKey histograms (underflow / in-axis / overflow):\n");
  const char* names[] = {"hITSChi2", "hTPCCrossedRows", "hDCAxy", "hDCAz",
                         "hNTrackPerEvt_All", "hNTrackPerEvt_Global"};
  for (const char* n : names) {
    stats(f, task, n);
  }
  f->Close();
}
