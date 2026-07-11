# SETUP.md — Bootstrap complet du framework o2.sh

Ce document couvre tout ce qui n'est **pas** dans le code git et doit être
refait manuellement sur toute nouvelle machine (PC local ou compte HPC).

Dépôts nécessaires :
- `github.com/guernane/o2-framework` (privé) — ce framework
- `github.com/guernane/analyses` — config et code des tâches d'analyse
- `github.com/guernane/O2Physics` (fork, branche `dev`) — code ALICE

---

## 1. PC local

### 1.1 Cloner les dépôts
```bash
git clone git@github.com:guernane/o2-framework.git ~/alice
cd ~/alice
git clone git@github.com:guernane/analyses.git analyses
```

### 1.2 Sourcer o2rc dans le shell
```bash
echo 'source ~/alice/o2rc' >> ~/.bashrc
source ~/.bashrc
```

### 1.3 Générer un token GitHub (fine-grained)
- Aller sur https://github.com/settings/personal-access-tokens
- Créer un token avec scopes : Contents (read/write) + Metadata (read-only)
- Cible : dépôt `guernane/O2Physics`
- Coller la valeur dans `~/alice/o2_config.sh` → `O2_GITHUB_TOKEN`
- ⚠️ Ne jamais coller ce token ailleurs que dans ce fichier (déjà gitignored
  pour les valeurs futures — attention : le tout premier commit
  de ce dépôt le contient encore en clair dans l'historique. Si ce
  dépôt devait être rendu public un jour, réécrire l'historique ou
  régénérer le token avant.)

### 1.4 Obtenir le certificat grid ALICE
- Suivre la procédure CERN CA (voir https://alice-doc.github.io/alice-analysis-tutorial/)
- Placer `usercert.pem` et `userkey.pem` dans `~/.globus/`
- Le framework les copiera automatiquement dans `fakehome/.globus/` au
  premier lancement (`common.sh` s'en charge)

### 1.5 Construire le sandbox + O2Physics (une seule commande, plusieurs heures)
`o2 build` gère tout en une fois : construction du sandbox Apptainer (à
partir de `alice_o2.def`) s'il n'existe pas encore, puis clone/build
d'O2Physics via aliBuild. Il n'y a pas de sous-commande `sandbox` séparée.
```bash
cd ~/alice
o2 build
```

---

## 2. Cluster HPC (CIMENT / dahu.ciment)

### 2.1 Compte et quota
- Demander un compte CIMENT + accès au projet OAR (actuellement
  `pr-alice_hic_btagging`) — démarche administrative, pas technique
- Vérifier le quota `/bettik/<user>/alice` (scratch, large quota)

### 2.2 Clé SSH non-interactive PC local → cluster
```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_dahu
ssh-copy-id -i ~/.ssh/id_ed25519_dahu.pub guernanr@dahu.ciment
```
Ajouter dans `~/.ssh/config` (PC local) :
```
Host dahu.ciment
    User guernanr
    IdentityFile ~/.ssh/id_ed25519_dahu
```

### 2.3 Déployer le framework sur le cluster
```bash
o2 deploy --sync-only
```
(rsync le framework + O2Physics + alidist vers le cluster ; ne synchronise
PAS `analyses/` en entier — voir note ci-dessous)

### 2.4 Certificat grid sur le cluster
```bash
ssh guernanr@dahu.ciment mkdir -p ~/.globus
scp ~/.globus/usercert.pem ~/.globus/userkey.pem guernanr@dahu.ciment:~/.globus/
ssh guernanr@dahu.ciment chmod 400 ~/.globus/userkey.pem
```

### 2.5 Déchiffrer la clé privée grid (nécessaire pour le mode batch/OAR)
```bash
ssh guernanr@dahu.ciment
cd ~/.globus
openssl rsa -in userkey.pem -out userkey_nopass.pem   # demande la passphrase une fois
chmod 400 userkey_nopass.pem
mv userkey.pem userkey_orig.pem.bak
mv userkey_nopass.pem userkey.pem
```
⚠️ Cette clé déchiffrée est très sensible — vérifier que
`~/.globus` a les permissions `700` et que ce fichier n'est jamais copié
hors du cluster.

### 2.6 Build initial sur le cluster (déclenché depuis le PC local)
Le build sur le cluster n'est jamais lancé en se connectant soi-même en SSH
puis en tapant la commande sur place — il est déclenché **depuis le PC
local**, qui pousse le job de build (via OAR) sur le cluster :
```bash
# Depuis le PC local, dans ~/alice
o2 deploy --build-only
```

---

## 3. Vérification finale

```bash
o2 sync          # doit afficher "IN SYNC" entre local et cluster
o2 run test LHC25f3 --runs 544013   # test de bout en bout
```

---

## Notes de reproductibilité connues (limitations actuelles)

- **`analyses/` n'est pas automatiquement synchronisé sur le cluster** —
  seul un `o2 deploy --sync-only` manuel le fait aujourd'hui. Un upgrade
  est en cours (`o2 run --hpc`, voir `UPGRADE_PLAN_o2_run_hpc.md`) pour
  éliminer ce besoin.
- Le token GitHub du tout premier commit d'`o2-framework` est visible dans
  l'historique git — à régénérer si ce dépôt change un jour de visibilité.
- Le nom du projet OAR et le quota HPC sont attribués administrativement
  par CIMENT et ne sont pas dans ce dépôt.
