#!/bin/bash

case "$1" in
	stage1)
		filename="stage1.html"
		;;
	stage2)
		filename="stage2.html"
		;;
	stage3)
		filename="stage3.html"
		;;
esac

(
	printf '%s' '<!doctype html><html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Aura Output</title>
<style>
/* ===== Aura Dark (Soft Text) ===== */
:root {
  --bg: #15141b;           /* editor.background */
  --fg: #bdbdbd;           /* editor.foreground */
  --black: #15141b;        --red: #c55858;        --green: #54c59f;
  --yellow: #c7a06f;       --blue: #8464c6;       --magenta: #54c59f;
  --cyan: #8464c6;         --white: #b4b4b4;
  --bblack: #2d2d2d;       --bred: #c7a06f;       --bgreen: #8464c6;
  --byellow: #c7a06f;      --bblue: #8464c6;      --bmagenta: #54c59f;
  --bcyan: #54c59f;        --bwhite: #bdbdbd;
}

/* ===== Light mode placeholder palette ===== */
[data-theme="light"] {
  --bg: #fdfdfd;
  --fg: #1e1e1e;
  --black: #000000;        --red: #c01c28;        --green: #26a269;
  --yellow: #a2734c;       --blue: #12488b;       --magenta: #a347ba;
  --cyan: #2aa1b3;         --white: #d0cfcc;
  --bblack: #555753;       --bred: #f66151;       --bgreen: #33d17a;
  --byellow: #e9ad0c;      --bblue: #3584e4;      --bmagenta: #c061cb;
  --bcyan: #33c7de;        --bwhite: #ffffff;
}

.aura-terminal {
  background: var(--bg);
  color: var(--fg);
  font-family: monospace;
  padding: 1rem;
  overflow-x: auto;
  white-space: pre;
}
.aura-terminal span { all: unset; }
</style>
</head><body>
<div class="aura-terminal">' \
		;
	./qbt-nox-static.bash \
		| aha --no-header \
		| sed 's/brightness(190%)/brightness(140%)/g' \
		;
	printf '%s\n' '</div></body></html>'
) > "${filename}"
