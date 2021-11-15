# pubspec-assist.nvim

A neovim clone of [pubspec-assist](https://github.com/jeroen-meijer/pubspec-assist) a plugin for adding and updating dart dependencies in pubspec.yaml files.

## Status:
This plugins is still in development.

## Installation
```lua
use {
  'akinsho/pubspec-assist.nvim',
  requires = 'plenary.nvim',
  rocks = {
    'semver',
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
