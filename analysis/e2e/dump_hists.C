// dump_hists.C
// Liste tous les objets d'un AnalysisResults.root (repertoires, TList, histos,
// THnSparse) avec leur nombre d'entrees, et signale ceux qui sont vides.
//
// Usage (dans le shell o2, depuis le dossier du fichier) :
//   root.exe -b -q 'dump_hists.C("AnalysisResults.root")' > hists.txt
//
// Non teste dans l'environnement de Claude (pas de ROOT disponible).

#include "TDirectory.h"
#include "TFile.h"
#include "TH1.h"
#include "THnBase.h"
#include "TKey.h"
#include "TList.h"
#include "TString.h"
#include <cstdio>

void visit(TObject* obj, const TString& path)
{
  if (!obj) {
    return;
  }
  if (obj->InheritsFrom(TDirectory::Class())) {
    TDirectory* dir = (TDirectory*)obj;
    TIter next(dir->GetListOfKeys());
    while (TKey* key = (TKey*)next()) {
      visit(key->ReadObj(), path + "/" + key->GetName());
    }
  } else if (obj->InheritsFrom(TList::Class())) {
    TIter next((TList*)obj);
    while (TObject* o = next()) {
      visit(o, path + "/" + o->GetName());
    }
  } else if (obj->InheritsFrom(TH1::Class())) {
    TH1* h = (TH1*)obj;
    printf("%-85s %-10s entries=%12.0f integral=%12.5g%s\n", path.Data(),
           h->ClassName(), h->GetEntries(), h->Integral(),
           h->GetEntries() == 0 ? "   <-- VIDE" : "");
  } else if (obj->InheritsFrom(THnBase::Class())) {
    THnBase* h = (THnBase*)obj;
    printf("%-85s %-10s entries=%12.0f%s\n", path.Data(), h->ClassName(),
           h->GetEntries(), h->GetEntries() == 0 ? "   <-- VIDE" : "");
  } else {
    printf("%-85s %s\n", path.Data(), obj->ClassName());
  }
}

void dump_hists(const char* fileName = "AnalysisResults.root")
{
  TFile* f = TFile::Open(fileName);
  if (!f || f->IsZombie()) {
    printf("Impossible d'ouvrir %s\n", fileName);
    return;
  }
  visit(f, "");
  f->Close();
}
