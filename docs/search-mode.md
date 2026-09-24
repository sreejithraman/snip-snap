# Search mode

Search starts as a circular button beside the current list or Clipboard title. Activating it expands the button into a field. The tabs and inline composer leave the panel while search is open, so results from every saved list and Clipboard history have room and no tab appears to own them.

The field uses the short hint “Search.” Its accessibility label names the full scope. An empty field invites a query; a nonempty field shows grouped results. The inset circle X and Escape clear the query, close search, and restore the selected tab. The search shortcut opens and focuses the field. The Clipboard shortcut opens Clipboard with search closed.

This direction replaced the inline status, results header, and search footer prototypes. The expanding control marks the change in mode without adding another row to the compact panel.

The header controls and composer keep their compact 32-point visible size. The tab capsule is 40 points high. Add List sits inside it as a fixed glass circle; tabs scroll beneath it with enough trailing space to reveal the last tab.
