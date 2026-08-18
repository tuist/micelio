# Credo configuration.
#
# Only two checks are tuned away from the defaults, and both are deliberate:
# see the comments at each. Everything else runs strict, and CI enforces it.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "config/", "mix.exs"],
        # Generated from priv/proto; regenerate rather than edit.
        excluded: [~r"/lib/micelio/wal/v1/wal.pb.ex$"]
      },
      strict: true,
      checks: %{
        enabled: [
          # A depth of two forces plumbing code into a chain of tiny private
          # functions that has to be read backwards. Three is enough to keep a
          # `case` inside a `with` inside a function readable in one place.
          {Credo.Check.Refactor.Nesting, max_nesting: 3},

          # Aliasing a module referenced once, in one clause, moves the
          # information away from where it is needed. Require it only when a
          # module is genuinely used repeatedly.
          {Credo.Check.Design.AliasUsage, if_called_more_often_than: 2, if_nested_deeper_than: 2}
        ],
        disabled: [
          # Documenting every private module is noise; the ones that matter
          # have moduledocs and they are the ones people read.
          {Credo.Check.Readability.ModuleDoc, []}
        ]
      }
    }
  ]
}
