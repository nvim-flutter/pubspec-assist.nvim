# pubspec-assist.nvim

A neovim clone of [pubspec-assist]() a plugin for adding and updating dart dependencies in pubspec.yaml files.

## Installation
```lua
use {
  'akinsho/pubspec-assist.nvim',
  requires = 'plenary.nvim',
  config = function()
    require('pubspec-assist').setup()
  end
}
```
