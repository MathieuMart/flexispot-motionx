# MotionX iOS

App iPhone (SwiftUI, iOS 17+) pour le serveur MotionX (`server.js` sur le NAS).

- **Direct** : état du tapis, vitesse, durée, distance, pas et calories estimés, profil de vitesse, en temps réel via `GET /api/stream` (SSE), avec repli sur `GET /api/live`.
- **Historique** : `GET /api/sessions` (résumé et graphique des 7 derniers jours, séances par jour), détail via `GET /api/sessions/<fichier>`.
- **Apple Santé** : remplace le raccourci. `GET /api/health/pending` → un entraînement « Marche » en intérieur (distance, kcal, pas) → `GET /api/health/done?file=…`.
  Anti-doublon : identifiant de synchro HealthKit `motionx.<fichier>`. Synchro à l'ouverture, à la fin de chaque séance (app ouverte) et en arrière-plan (BGAppRefresh).

- **Live Activity** (écran verrouillé + Dynamic Island) : vitesse, chrono de marche, distance, pas, kcal. Démarre quand une séance commence avec l'app ouverte, se termine avec un résumé affiché 10 min. Sans push (Personal Team), c'est l'app qui met à jour ; l'option « Mise à jour écran verrouillé » la garde éveillée pendant la séance avec du silence audio mélangé (mode `audio`, OK pour un usage perso, refusé sur l'App Store).

Aucune modification du serveur n'est nécessaire.

## Installer sur l'iPhone

1. Ouvrir `MotionX.xcodeproj` dans Xcode.
2. Cible MotionX › Signing & Capabilities : choisir ton Team (et changer le bundle id `ch.perso.motionx` s'il est déjà pris).
3. Brancher l'iPhone (mode développeur activé), le choisir comme destination, puis ⌘R.
4. Dans l'app, onglet Réglages : saisir l'adresse du serveur, par ex. `192.168.1.10:3000`, puis Tester, Enregistrer et « Autoriser l'accès à Santé ».

Avec un compte Apple gratuit, l'app doit être réinstallée tous les 7 jours (limite Apple) ; avec un compte développeur payant, c'est tous les ans.

## Notes

- HTTP en clair autorisé (ATS) pour joindre le NAS en local ; hors de chez toi, passer par un VPN (Tailscale, WireGuard…).
- Les pas et calories en direct utilisent les mêmes formules que `server.js` (profil HEIGHT_CM / WEIGHT_KG lu sur le serveur).
