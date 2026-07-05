# frozen_string_literal: true
# lib/vmctl/substitution.rb
module VMCtl
  # Replace %(word) tokens from vars (string keys); unknown tokens pass through.
  def self.substitute(text, vars)
    text.gsub(/%\((\w+)\)/) { vars.fetch(Regexp.last_match(1), Regexp.last_match(0)) }
  end
end
