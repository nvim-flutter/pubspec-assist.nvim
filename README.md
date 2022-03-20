# pubspec-assist.nvim

A neovim clone of [pubspec-assist](https://github.com/jeroen-meijer/pubspec-assist) a plugin for adding and updating dart dependencies in pubspec.yaml files.

<img width="827" alt="Screen Shot 2022-03-20 at 21 24 28" src="https://user-images.githubusercontent.com/22454918/159186795-c26bd9e8-2476-430a-8c97-b051b1f9648e.png">

## Features

Version picker (using `vim.ui.select`)

<img width="959" alt="Screen Shot 2022-03-20 at 21 24 45" src="https://user-images.githubusercontent.com/22454918/159186794-666a29f3-8668-4eae-b0d7-8384b4e7d9b8.png">

Package search (using `vim.ui.input`)

<img width="659" alt="Screen Shot 2022-03-20 at 21 34 18" src="https://user-images.githubusercontent.com/22454918/159186904-3a1a11e6-3c46-44ab-8ba3-a747eeb5eddf.png">

## Status:

This plugin is in _alpha_ but should be stable enough for daily usage.

## Requirements:

- `nvim 0.7+`
- `plenary.nvim`

## Installation

```lua
use {
  'akinsho/pubspec-assist.nvim',
  requires = 'plenary.nvim',
  rocks = {
    {
      'lyaml',
      server = 'http://rocks.moonscript.org',
      -- If using macOS or Ubuntu, you may need to install the `libyaml` package.
      -- if you install libyaml with homebrew you will need to set the YAML_DIR
      -- to the location of the homebrew installation of libyaml e.g.
      -- env = { YAML_DIR = '/opt/homebrew/Cellar/libyaml/0.2.5/' },
    },
  },
  config = function()
    require('pubspec-assist').setup()
  end,
}
```

## Contributing

If you decide to use this plugin but want to see X feature implemented, then rather than making feature requests consider
contributing PRs instead. I won't be taking a endless feature requests and the best way to see a feature want implemented
is to contibute it yourself.
