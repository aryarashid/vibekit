# Vibe Kit design brief

Who visits: A developer on a Mac with several projects and agents running at once. They click the menu bar icon in the middle of other work, often with a terminal or editor in front. (assumed)
What they need done here: "What is running, on which port, from which project, and let me open, restart or kill it right now."
The question every screen answers first: Which dev servers are running on my machine right now, and on what ports?
Tone: precise, calm, alive · Not: dashboard-noisy, toy-like, Electron-heavy
Taste references: macOS Control Center and menu bar extras (native glass, no chrome) · hardware instrument panels and rack meters (numerals you read at a glance, live traces) · Raycast (keyboard first, type to filter) (assumed)
Where to be bold: The port number is the hero of each row, set large in monospaced numerals, with a live CPU trace beside it. Developers name servers by port ("the thing on 3000"), so the design does too. (assumed)
Never: badges that shout, confirmation dialogs for single stops, fake data, polling that keeps the fan on, an app window in the Dock
The one thing people should remember: The column of port numerals with a small live heartbeat trace next to each, colored by framework.
Good means: Open the panel, find the server in under two seconds, act on it in one click or one key, and never notice Vibe Kit in Activity Monitor.
Public or private: Everything shown is local machine state. Environment variables are read only to restart a process and never stored on disk or shown.
Tokens: System font (SF Pro) and SF Mono, system glass and materials, one color per framework, system green, amber and red for status. Light and dark follow the system.
