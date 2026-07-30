#!/usr/bin/env ruby
# frozen_string_literal: true

require "psych"

def check_node(node, file, path, errors)
  return if node.nil? || node.children.nil?

  if node.is_a?(Psych::Nodes::Mapping)
    seen = {}
    node.children.each_slice(2) do |key_node, value_node|
      if key_node.is_a?(Psych::Nodes::Scalar)
        key = key_node.value
        if seen.key?(key)
          errors << "#{file}:#{key_node.start_line + 1}: duplicate YAML key " \
                    "#{(path + [key]).join(".")} " \
                    "(first declared on line #{seen.fetch(key)})"
        else
          seen[key] = key_node.start_line + 1
        end
        check_node(value_node, file, path + [key], errors)
      else
        check_node(key_node, file, path, errors)
        check_node(value_node, file, path, errors)
      end
    end
  else
    node.children.each { |child| check_node(child, file, path, errors) }
  end
end

files = ARGV
abort "usage: #{$PROGRAM_NAME} <yaml-file> [...]" if files.empty?

errors = []
files.each do |file|
  root = Psych.parse_file(file)
  check_node(root, file, [], errors)
rescue Psych::SyntaxError => error
  errors << error.message
end

unless errors.empty?
  warn errors.join("\n")
  exit 1
end

puts "No duplicate YAML keys found in #{files.length} file(s)."
