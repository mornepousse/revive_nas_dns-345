# nas_dns-345 — Claude Code instructions

## Les deux suites de test ne sont pas interchangeables

- `test/run_tests.sh` — recette d'acceptation **matérielle**, à lancer sur le NAS
  lui-même. Elle lit `/proc/mdstat`, ping la passerelle, interroge `smartctl` et
  `systemctl`. Sur une machine de dev ou un runner CI elle est **garantie rouge**.
  Ni `check.sh`, ni les hooks, ni la CI ne la lancent.
- `test/host_checks.sh` — les portes exécutables hors cible. C'est ce que lance
  `check.sh`, donc les hooks et la CI.

Ne jamais brancher `run_tests.sh` sur le tripwire.

## Workflow anti-régression (OBLIGATOIRE)

Source unique de vérité : `scripts/check.sh`.
- `./scripts/check.sh --fast` — syntaxe shell + Python, compilation du DTS, cohérence des chemins du README (~secondes)
- `./scripts/check.sh` — fast + le check strict (shellcheck niveau warning)

Les portes de `test/host_checks.sh` :

| # | Porte | Mode |
|---|---|---|
| 1 | `bash -n` sur les scripts shell suivis par git | fast |
| 2 | `shellcheck -S error` | fast |
| 3 | syntaxe Python (`ast.parse`, pas `py_compile` — pas de `__pycache__`) | fast |
| 4 | `dtc` sur `boot/kirkwood-dns345.dts`, code retour seul (avertissements préexistants) | fast |
| 5 | tout chemin `scripts/…`, `tftp/…`, `boot/…`, `test/…`, `images/…` cité par le README existe | fast |
| 6 | tests unitaires `test/unit_*.sh` (logique pure, sans matériel) | fast |
| 7 | `shellcheck -S warning` | full |

`shellcheck` et `dtc` (`device-tree-compiler`) sont **requis** : leur absence est
un échec, pas un skip.

**Activation des hooks git (une fois par clone)** :
```bash
./scripts/install-hooks.sh   # ou: git config core.hooksPath scripts/hooks
```
`pre-push` lance le check complet et bloque le push si rouge. WIP : `git push --no-verify`.

**Hooks Claude Code** (`.claude/settings.json`, automatiques) :
- `PostToolUse` sur édition d'un fichier surveillé → `check.sh --fast`.
- `Stop` → `check.sh --fast` (garde-fou ~1 s avant de conclure). Le build complet
  (le check strict (shellcheck niveau warning)) n'est PAS relancé à chaque fin de
  tour : il reste garanti au pre-push git.

**Ratchet de tests** : `.tripwire-testcount` (committé) mémorise le nombre
d'assertions de `test/run_tests.sh` (`pass`/`fail`/`warn`). Une baisse est
bloquante au pre-push. Retirer une vérification matérielle est donc possible,
mais laisse un diff visible en review.

**Divergences déclarées** : `.tripwire-divergences` (committé) liste les écarts
assumés au scaffold standard — mode maison, dégradation d'environnement, alias
de dialecte. Une ligne `fichier<TAB>motif<TAB>pourquoi` ; `check.sh` rend rouge
la disparition d'un motif déclaré. Le fichier hôte d'une divergence doit être
**suivi par git** : un fichier gitignoré ne change pas l'empreinte du
skip-si-déjà-vert, donc sa perte peut passer sous un « déjà vert — skip » — il
n'est pas protégé de façon fiable. **Limite** : un écart non déclaré n'est
protégé par rien et le prochain re-scaffold l'effacera — toute divergence
délibérée se déclare au moment où on l'introduit.

Ce repo en déclare **une** : `scripts/check.sh` porte un
`# shellcheck disable=SC2254`. La porte 6 lint `check.sh` lui-même, et SC2254 y
est un faux positif — le motif de `MODULE_FAST` doit rester interprété comme un
glob. Le directive est un ajout local au template v0.11.0 ; si elle disparaît,
`check.sh` devient rouge.

### Norme TDD — nouvelle logique pure
Toute nouvelle fonction de logique pure (parsing /proc et /sys, checksum U-Boot,
hystérésis du ventilateur) : test écrit **d'abord**, ajouté à la suite de tests
de la phase rapide. Le test doit être rouge avant l'implémentation, vert après,
et parallel-safe (pas d'état global muté).

Le code le plus exposé du repo est `scripts/patch_uboot.py` : il réécrit le
bootcmd à l'offset `0x4FAAD` et recalcule le checksum kwbimage. Une erreur y
brique le NAS, et rien ne la rattrape aujourd'hui — toute modification de ce
fichier mérite un test avant le code.

### Économie de modèles (subagents)
Le pipeline check.sh permet de descendre en gamme SANS risque d'hallucination,
mais seulement là où un oracle rattrape l'erreur :
- **Modèle économique (haiku) OK** : transcription de code déjà spécifié,
  refactors mécaniques, extraction citée (`fichier:ligne` obligatoire) — le
  check, la compilation ou le recoupement des citations attrapent la dérive.
- **Jamais en dessous de sonnet** : review, audit, debug, **et l'écriture
  d'assertions de test** — une assertion tautologique ou un verdict halluciné
  passent l'oracle mécanique au vert. Le jugement ne descend pas en gamme.
- Toute tâche économique DOIT finir par `./scripts/check.sh --fast` vert, et
  un test rewiré/écrit DOIT prouver qu'il mord (bug transitoire → rouge → revert).
