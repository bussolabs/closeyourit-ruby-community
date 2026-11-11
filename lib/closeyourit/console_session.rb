# frozen_string_literal: true

module CloseYourIt
  # Tells whether this process is a one-off command typed by a person: `rails console` and
  # `rails runner` (a script, inline code or code piped to `-`). Their mistakes belong to whoever
  # typed them, not to the application, and they were the single biggest source of errors closed by
  # hand: 36 groups in one day with culprits `p28.rb`, `np.rb`, `stdin`, `rails in <main>` — e.g.
  # `NameError: uninitialized constant Project` (CYRB-47).
  #
  # Detection reads the command class Rails loaded to run the process. `Rails::Command.invoke`
  # requires ONLY the file of the command being run (`lookup`, one glob per namespace), so the
  # constant exists exactly when that command is driving the process. The whole-catalogue require
  # (`lookup!`) happens only to print the help, where there is no app to report errors for.
  #
  # Deliberately NOT in this family: `rake`, `bin/jobs`/Solid Queue, Sidekiq, the web server. That
  # work is scheduled, nobody is watching the terminal, and its errors must keep arriving.
  module ConsoleSession
    # Rails command classes that mean "a person is driving this process".
    COMMAND_CLASSES = %w[
      Rails::Command::ConsoleCommand
      Rails::Command::RunnerCommand
    ].freeze

    class << self
      def active?
        COMMAND_CLASSES.any? { |name| Object.const_defined?(name) }
      end
    end
  end
end
