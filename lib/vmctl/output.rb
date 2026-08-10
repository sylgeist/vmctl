# frozen_string_literal: true
# lib/vmctl/output.rb

module VMCtl
  # Shared helpers for column-aligned, optionally colorized command output.
  # Used by the `list`, `status`, and `info` commands so multi-VM output
  # reads consistently across the CLI.
  module Output
    COLORS = { green: 32, gray: 90, yellow: 33, red: 31 }.freeze

    module_function

    # Wraps text in an ANSI color code; a no-op when stdout isn't a tty
    # (piped/redirected output stays plain text).
    def colorize(text, color)
      return text unless $stdout.tty?
      "\e[#{COLORS.fetch(color)}m#{text}\e[0m"
    end

    # Prints a left-aligned table. `rows` is an array of arrays of strings,
    # one array per row, matching `headers` in length. Cells may contain
    # ANSI color codes from `colorize` — those don't count toward column
    # width. The last column is left unpadded.
    def table(headers, rows)
      widths = headers.each_index.map do |i|
        ([headers[i].length] + rows.map { |r| visible_length(r[i]) }).max
      end

      puts pad_row(headers, widths)
      rows.each { |row| puts pad_row(row, widths) }
    end

    def pad_row(cells, widths)
      last = cells.length - 1
      cells.each_with_index.map do |cell, i|
        i == last ? cell : cell + (' ' * (widths[i] - visible_length(cell)))
      end.join('  ').rstrip
    end

    def visible_length(text)
      text.gsub(/\e\[\d+m/, '').length
    end
  end
end
