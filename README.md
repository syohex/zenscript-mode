# ZenScript Mode

`zenscript-mode` is an Emacs major mode for editing
[ZenScript](https://github.com/CraftTweaker/ZenScript) code.

It provides font-lock, indentation, syntax checking and,
currently primitive, code completion.

# Installing

`zenscript-mode` can currently be installed in the following way:

## Manual Installation

To install `zenscript-mode` manually:

1. Clone this repo into your `~/.emacs.d/` folder.
2. Add the following to your `~/.emacs.d/init.el` or `~/.emacs` file:
   ```lisp
   (add-to-list 'load-path "~/.emacs.d/zenscript-mode")
   (require 'zenscript-mode)
   ```

# Usage

To make the most of `zenscript-mode`, it is important to provide
it ZenScript dumps. To do this, in game, run the commands:
`/ct dumpzs json` and `/ct dumpzs html`.

Then, when editing scripts from the `scripts/` folder of that instance,
`zenscript-mode` will be able to provide code completion.

If `zenscript-mode` cannot find these files, it will ask where they are.
If you do not have these files, <kbd>C-g</kbd> will quit, and `zenscript-mode`
won't provide code completion.
