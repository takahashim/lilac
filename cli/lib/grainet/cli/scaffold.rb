# frozen_string_literal: true

require "fileutils"
require "pathname"

module Grainet
  module CLI
    # Generates a new Grainet app skeleton under `<root>/<name>/`:
    #
    #   <name>/
    #   ├── .gitignore
    #   ├── Gemfile
    #   ├── README.md
    #   ├── pages/index.html
    #   └── components/counter.gnt
    #
    # Templates live under `lib/grainet/cli/templates/`. Files are copied
    # 1:1 with `{{name}}` substituted to the chosen project name. The
    # `.gitignore` template is shipped as `gitignore` (no leading dot) so
    # the gem's own working-directory tools don't treat it as a directive
    # for the templates folder; it gets the dot prefix at copy time.
    class Scaffold
      class Error < StandardError; end

      TEMPLATES_DIR = File.expand_path("templates", __dir__)

      # Project names must look like a valid directory + future gem-ish
      # identifier: ASCII lowercase letters, digits, hyphens, underscores,
      # starting with a letter.
      NAME_PATTERN = /\A[a-z][a-z0-9_-]*\z/

      def initialize(name, root: Dir.pwd)
        @name = name
        @root = root
        validate_name!
      end

      # Returns the list of relative paths written.
      def run
        dest = File.expand_path(@name, @root)
        raise Error, "Destination already exists: #{dest}" if File.exist?(dest)

        FileUtils.mkdir_p(dest)
        copy_templates(dest)
      end

      private

      def validate_name!
        raise Error, "Project name is required" if @name.nil? || @name.empty?
        unless @name.match?(NAME_PATTERN)
          raise Error, "Invalid project name #{@name.inspect}; must match [a-z][a-z0-9_-]*"
        end
      end

      def copy_templates(dest_root)
        # FNM_DOTMATCH so dot-prefixed templates (e.g. `public/.gitkeep`)
        # are included. `File.file?` already excludes the `.` / `..`
        # directory entries that FNM_DOTMATCH surfaces.
        sources = Dir.glob(File.join(TEMPLATES_DIR, "**", "*"), File::FNM_DOTMATCH)
                     .select { |p| File.file?(p) }
                     .sort

        sources.map do |source|
          rel = relative_template_path(source)
          target = File.join(dest_root, rel)
          FileUtils.mkdir_p(File.dirname(target))
          File.write(target, substitute(File.read(source)))
          rel
        end
      end

      def relative_template_path(source)
        rel = Pathname.new(source).relative_path_from(Pathname.new(TEMPLATES_DIR)).to_s
        # `gitignore` → `.gitignore` only when it's a top-level entry; a
        # `components/gitignore` wouldn't be silently renamed.
        rel == "gitignore" ? ".gitignore" : rel
      end

      def substitute(content)
        content.gsub("{{name}}", @name)
      end
    end
  end
end
