require "kilt"
require "logger"
require "habitat"

# Patch habitat to work with generics.
# See: https://github.com/luckyframework/habitat/pull/34
class Habitat
  module SettingsHelpers
    macro inherit_habitat_settings_from_superclass
      {% if @type.superclass && @type.superclass.type_vars.size == 0 && @type.superclass.constant(:HABITAT_SETTINGS) %}
        {% for decl in @type.superclass.constant(:HABITAT_SETTINGS) %}
          {% HABITAT_SETTINGS << decl %}
        {% end %}
      {% end %}
    end
  end

  macro create_settings_methods(type_with_habitat)
    {% type_with_habitat = type_with_habitat.resolve %}

    class Settings
      {% if type_with_habitat.superclass && type_with_habitat.superclass.type_vars.size == 0 && type_with_habitat.superclass.constant(:HABITAT_SETTINGS) %}
        {% for decl in type_with_habitat.superclass.constant(:HABITAT_SETTINGS) %}
          def self.{{ decl.var }}
            ::{{ type_with_habitat.superclass }}::Settings.{{ decl.var }}
          end
        {% end %}
      {% end %}

      {% for decl in type_with_habitat.constant(:HABITAT_SETTINGS) %}
        {% if decl.type.is_a?(Union) && decl.type.types.map(&.id).includes?(Nil.id) %}
          {% nilable = true %}
        {% else %}
          {% nilable = false %}
        {% end %}

        {% has_default = decl.value || decl.value == false %}
        @@{{ decl.var }} : {{decl.type}} | Nil {% if has_default %} = {{ decl.value }}{% end %}

        def self.{{ decl.var }}=(value : {{ decl.type }})
          @@{{ decl.var }} = value
        end

        def self.{{ decl.var }}
          @@{{ decl.var }}{% if !nilable %}.not_nil!{% end %}
        end

        def self.{{ decl.var }}?
          @@{{ decl.var }}
        end
      {% end %}
    end
  end
end

module ActionController
  VERSION = "1.0.1"

  class Error < ::Exception
  end
end

require "./action-controller/router"
require "./action-controller/errors"
require "./action-controller/base"
require "./action-controller/file_handler"
