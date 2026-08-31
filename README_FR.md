[English](./README.md) · [简体中文](./README_ZH.md) · [繁體中文](./README_ZH_HANT.md) · [한국어](./README_KO.md) · [日本語](./README_JA.md) · [Русский](./README_RU.md) · Français

<p align="center">
  <img src="Resources/AppIcon.png" alt="CodexRunway logo" width="128" height="128">
</p>

# CodexRunway

Combien de temps votre Codex peut-il encore tourner ?

CodexRunway est une application native de barre de menus macOS pour consulter les quotas Codex et Grok. Elle fournit aussi le statut de réinitialisation Codex du jour, les reset credits, le coût équivalent API et les sessions locales, avec une gestion multi-comptes séparée pour chaque fournisseur.

## Points forts

- Consulter le quota Codex restant depuis la barre de menus.
- Basculer via les onglets toujours visibles `Codex | Grok` ; la barre de menus et le menu contextuel suivent le fournisseur sélectionné.
- Voir le quota Grok inclus, la répartition produit (Build / Imagine / Chat), les périodes hebdomadaires/mensuelles, le solde prépayé et l’usage à la demande via l’API de facturation officielle CLI chat-proxy.
- Sur le panneau Grok, réutiliser les mêmes modules Token Usage (carte de chaleur / ligne / barres) et coût équivalent API que Codex, plus les sessions locales récentes des journaux Grok CLI.
- Gérer plusieurs comptes Grok OAuth / SuperGrok avec connexion isolée, import de la connexion actuelle, collage de jeton/JSON, actualisation, alias, ordre, suppression et basculement explicite.
- Voir les fenêtres de quota 5 heures, hebdomadaire et supplémentaires.
- Savoir si les limites Codex ont été réinitialisées aujourd’hui (données de [www.codexrunway.com](https://www.codexrunway.com), avec un lien vers le message public associé).
- Activer la section « réinit. aujourd’hui ? » dans les réglages et configurer son propre intervalle d’actualisation (activé par défaut, toutes les 5 minutes).
- Gérer plusieurs comptes Codex : connexion navigateur, import du `auth.json` local, collage de jeton/JSON (y compris `/auth/session`), import de fichiers ou ajout d’une clé API.
- Basculer de compte en toute sécurité après confirmation en écrivant atomiquement `~/.codex/auth.json`, avec un redémarrage Codex optionnel pour que CLI / IDE restent synchronisés.
- Afficher le compte actuel, le niveau d’abonnement et l’expiration.
- Estimer le quota Codex de la semaine à partir du pourcentage hebdomadaire officiel et des Credits journaliers, le comparer aux semaines précédentes pour repérer une baisse, et activer le module dans les réglages (activé par défaut).
- Voir le nombre de crédits de réinitialisation, le statut et l’heure d’expiration.
- Voir le coût équivalent API et l’usage de jetons pour aujourd’hui, le cycle actuel, le cycle précédent, ce mois-ci ou une plage personnalisée ; la plage par défaut se règle dans les préférences.
- Afficher un graphique d’usage des jetons depuis le début de l’année sous le quota du panneau principal (carte de chaleur / ligne / barres ; quotidien / hebdomadaire / cumulé) ; le style se change dans le panneau et les réglages, carte de chaleur par défaut ; peut être désactivé.
- Utiliser un index de session incrémental local pour accélérer les analyses de coût.
- Voir les sessions Codex récentes, les projets, le statut et les résumés d’usage.
- Réparer l’index de session local.
- Prendre en charge les apparences claire, sombre et système, ainsi que English, 简体中文, 繁體中文, 한국어, 日本語, Русский, Français.
- Prendre en charge la recherche de mises à jour intégrée.
- Proposer des widgets bureau macOS 14+ pour l’aperçu des quotas, la tendance des jetons, un indicateur clé et le statut de réinit. du jour.

## Captures d’écran

<p align="center">
  <img src="docs/images/1.webp" alt="Aperçu des quotas CodexRunway" width="260">
  <img src="docs/images/2.webp" alt="Détails des crédits de réinitialisation CodexRunway" width="260">
  <img src="docs/images/3.webp" alt="Coût équivalent API CodexRunway" width="260">
  <img src="docs/images/4.webp" alt="Page des réglages CodexRunway" width="260">
  <img src="docs/images/5.webp" alt="Multi-comptes CodexRunway" width="260">
  <img src="docs/images/6.webp" alt="Quota Grok CodexRunway" width="260">
</p>

## Installation

### Homebrew (recommandé)

Installer depuis le [Licoy Homebrew Tap maintenu par le projet](https://github.com/Licoy/homebrew-tap) :

```bash
brew install --cask licoy/tap/codex-runway
```

CodexRunway prend aussi en charge les mises à jour dans l’app. Pour forcer Homebrew à vérifier et installer une mise à niveau :

```bash
brew upgrade --cask --greedy codex-runway
```

La désinstallation conserve par défaut les réglages et les copies de comptes gérés. Ajouter `--zap` retire aussi les données sous `~/.codex-runway`, sans supprimer les répertoires officiels `~/.codex` ou `~/.grok` ni les sessions :

```bash
brew uninstall --cask codex-runway
brew uninstall --cask --zap codex-runway
```

### Installation manuelle

Téléchargez le DMG correspondant depuis [GitHub Releases](https://github.com/Licoy/codex-runway/releases) :

- Apple Silicon : `CodexRunway-macos-arm64.dmg`
- Intel : `CodexRunway-macos-x86_64.dmg`

Ouvrez le DMG et glissez `CodexRunway.app` dans `Applications`, ou téléchargez et décompressez le ZIP de la même architecture.

### Blocages de sécurité macOS

Les versions actuelles sont signées ad hoc et non notariées. Si macOS indique que le développeur ne peut pas être vérifié ou que l’app n’a pas été contrôlée pour les logiciels malveillants, cliquez en maintenant Control sur `CodexRunway.app` puis choisissez Ouvrir, ou allez dans Réglages Système > Confidentialité et sécurité et cliquez sur Ouvrir quand même.

Si macOS indique que `CodexRunway.app` est endommagé et doit être mis à la Corbeille, c’est généralement l’attribut de quarantaine du téléchargement. Après avoir placé l’app dans `Applications`, exécutez :

```bash
xattr -dr com.apple.quarantine /Applications/CodexRunway.app
```

Puis rouvrez l’application.

## Prérequis

- macOS 12+
- Codex installé et utilisé sur ce Mac est recommandé
- Importer depuis le `~/.codex/auth.json` local, ou ajouter des comptes dans l’app (connexion navigateur, collage d’identifiants, import de fichiers, etc.)
- Avant d’utiliser le panneau Grok, installez le [CLI Grok officiel](https://docs.x.ai/build/overview) :

  ```bash
  curl -fsSL https://x.ai/cli/install.sh | bash
  ```

- La gestion des comptes Grok et la facturation ne prennent en charge que OAuth / SuperGrok et les sessions legacy compatibles. Exécutez `grok login --oauth`, connectez-vous depuis l’app, importez la connexion actuelle, ou collez `~/.grok/auth.json` / un JSON d’identifiants. Les identifiants uniquement par clé API ne sont pas ajoutés comme comptes gérés.
- Si `GROK_HOME` est défini, l’app utilise ce répertoire ; sinon `~/.grok`. Voir [xAI Settings](https://docs.x.ai/build/settings).

## Exécution locale

```bash
swift run CodexRunway
```

Sous macOS 14+, cette commande compile et enregistre automatiquement une app `CodexRunway Dev` séparée et une extension Widget, puis la lance. L’app de développement se trouve dans `.build/codex-runway-widget-dev/CodexRunway-dev.app` et peut être ajoutée depuis la galerie de widgets système. Quittez d’abord toute autre instance CodexRunway. Définissez `CODEX_RUNWAY_DISABLE_DEV_APP=1` seulement si vous voulez le processus en ligne de commande non empaqueté, sans widgets.

Auto-diagnostic :

```bash
swift run CodexRunway --self-check
```

L’auto-diagnostic ne lit que l’état local et n’effectue aucune requête réseau. Il affiche un diagnostic Codex expurgé plus la version du CLI Grok, l’état des identifiants et l’identité du compte. Les jetons et clés API ne sont jamais affichés.

## Widgets bureau

Les widgets bureau nécessitent macOS 14 ou plus. À partir d’une version contenant ce correctif, les versions publiques et les builds de développement locaux incluent l’extension Widget. Chaque widget peut choisir indépendamment Codex, Grok ou les deux dans Modifier le widget ; Réinit. du jour est réservé à Codex. Après mise à niveau, macOS enregistre le widget de production depuis `Contents/PlugIns` de l’app.

`swift run CodexRunway` utilise des identifiants `swift-dev` séparés et ne remplace pas une installation existante. Vous pouvez aussi empaqueter manuellement une app avec widgets et identifiants `.dev` :

```bash
INCLUDE_WIDGET=1 \
RUNWAY_BUNDLE_ID=com.github.codex-runway.dev \
RUNWAY_APP_GROUP_ID=group.com.github.codex-runway.dev \
RUNWAY_WIDGET_STORAGE_MODE=local \
bash Scripts/package-app.sh
```

L’app est écrite dans `dist/CodexRunway.app`. Les versions publiques contenant ce correctif et les builds ad hoc locaux utilisent l’instantané dérivé versionné en lecture seule `~/.codex-runway/widget-snapshot.json` avec les droits `0600`. Un build Developer ID avec un App Group enregistré peut utiliser `RUNWAY_WIDGET_STORAGE_MODE=app-group`. L’instantané ne contient ni e-mail, ni ID de compte, ni jeton, ni JSON d’auth, ni texte brut d’événement externe. La signature Developer ID, l’enregistrement App Group et la notarisation restent un travail de distribution futur.

## Confidentialité

- Les jetons sont lus depuis le `~/.codex/auth.json` local ; les identifiants multi-comptes sont stockés uniquement sous `~/.codex-runway/accounts/<id>/auth.json` (répertoire `0700`, fichier `0600`). L’index des comptes `index.json` ne contient jamais de jetons.
- Les identifiants Grok officiels sont lus depuis `$GROK_HOME/auth.json` (ou `~/.grok/auth.json` s’il n’est pas défini). Les copies gérées sont dans `~/.codex-runway/accounts/grok-<stable-id>/auth.json` en mode répertoire `0700` et fichier `0600` ; le `~/.codex-runway/accounts/grok-index.json` séparé ne contient pas de jetons.
- Le quota Grok est demandé avec l’identifiant OAuth local auprès du point d’accès officiel CLI chat-proxy `/v1/billing?format=credits` (la même API officielle que le CLI Grok). L’app ne lit pas les cookies du navigateur et n’infère pas de faux quota à partir des sessions locales.
- Pendant l’actualisation du compte Grok actuel, le CLI officiel peut faire tourner les jetons ; l’app recopie les identifiants officiels résultants uniquement vers ce compte géré. Les comptes non actuels utilisent un `GROK_HOME` isolé et n’écrivent jamais les identifiants officiels.
- Un basculement de compte Grok ne remplace que les portées de connexion OAuth / legacy compatibles dans les identifiants officiels, tout en conservant la clé API et les portées inconnues. Un basculement n’est garanti que pour les nouvelles sessions. Les processus Grok en cours ne sont pas arrêtés et peuvent réécrire le compte précédent, donc l’app affiche un avertissement fort avant de continuer.
- Le `~/.codex/auth.json` officiel n’est écrasé que lorsque vous confirmez un basculement de compte (écriture atomique), pour que Codex CLI / IDE restent synchronisés.
- Actualiser un compte géré inactif met à jour uniquement sa copie bibliothèque, pas le `auth.json` officiel. Actualiser le compte actif synchronise le fichier auth officiel et la copie bibliothèque.
- Les identifiants invalides ou mock ne sont jamais réécrits dans le `~/.codex/auth.json` officiel.
- Les jetons d’accès, de rafraîchissement, d’identité et les clés API ne doivent pas être écrits dans les journaux, les README, les modèles d’issue ou la sortie d’auto-diagnostic.
- Le coût équivalent API est calculé par défaut à partir des journaux JSONL de session locaux, avec des données dérivées comme un index incrémental local sous `~/.codex-runway/`. Le contenu des sessions n’est pas téléversé.
- L’estimation de quota n’enregistre que des totaux Credits et pourcentages dérivés dans `~/.codex-runway/quota-estimate-history.json`. Pas de jetons ni de clés.
- L’usage en ligne complète le coût équivalent API seulement lorsque les données de jetons locales sont indisponibles. La série « Stats officielles (tous les appareils) » du graphique vient des statistiques de profil du compte actuel et peut être en retard ou révisée ; « Journaux locaux (toutes les sessions) » analyse les sessions présentes sur ce Mac et l’historique peut couvrir plusieurs comptes. Les deux séries ne sont pas une relation d’inclusion et ne doivent pas être soustraites.
- La réparation des sessions ne touche que `~/.codex/session_index.jsonl`, crée une sauvegarde avant d’écrire et ne supprime jamais les fichiers de session.
- « Réinit. aujourd’hui ? » ne télécharge que le flux de statut public. Il n’envoie aucun compte Codex, jeton ou contenu de session locale.
- La recherche de mises à jour ne demande que des informations de version. Les données de compte et de session Codex ne sont pas téléversées.
- Le stockage d’instantané du widget ne contient que des données dérivées non secrètes de quota, solde, coût, jetons quotidiens et statut de réinit. L’app principale est la seule à écrire ; les widgets sont en lecture seule.

## Sources de données

- **Réinit. aujourd’hui ?** : les données viennent de [https://www.codexrunway.com/api/status.json](https://www.codexrunway.com/api/status.json). Non officiel et indicatif seulement ; peut être retardé ou temporairement indisponible.
- **Quota / reset credits / estimation de quota / usage officiel des jetons / une partie de l’usage en ligne** : une fois connecté, les requêtes utilisent vos identifiants locaux contre les API backend officielles ChatGPT / Codex. L’usage officiel des jetons appartient au compte actuel et affiche la date des statistiques backend. L’estimation de quota est non officielle : le quota hebdomadaire est extrapolé du pourcentage utilisé et des Credits journaliers (1000 Credits ≈ $40, version `credits-usd-2026-08-26`).
- **Quota Grok** : renvoyé uniquement par le point d’accès officiel CLI chat-proxy `/v1/billing?format=credits` avec une connexion OAuth / SuperGrok locale. Il n’y a pas de source secondaire, et la facturation API ou les statistiques de sessions locales ne sont pas mélangées à ce quota.
- **Coût équivalent API Grok / sessions locales** : calculé à partir de l’usage `turn_completed` de `~/.grok/sessions` local selon les prix officiels xAI Text API (input / cached / output ; prompt ≥ 200k utilise les tarifs long contexte ; barème `xai-builtin-2026-08-13`). Les modèles inconnus ne sont pas inventés comme des coûts exacts. Le `costUsdTicks` du CLI est une comptabilité de crédits d’abonnement et n’est pas utilisé comme coût équivalent API.
- **Usage de jetons des journaux locaux / coût équivalent API / sessions récentes** : calculé par défaut à partir des journaux de session `~/.codex` locaux et de l’index local. Les journaux historiques locaux n’ont pas d’attribution de compte fiable, ils peuvent donc inclure plusieurs comptes.

## Développement et contribution

```bash
swift test
swift build
swift build -c release
```

Voir [CONTRIBUTORS.md](CONTRIBUTORS.md) pour les notes de contribution.

## Communauté

- [LinuxDO](https://linux.do/)

## Licence

Ce projet suit le [LICENSE](LICENSE) du dépôt.
