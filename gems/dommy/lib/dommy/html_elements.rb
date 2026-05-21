# frozen_string_literal: true

module Dommy
  # Base for specialized HTMLElement subclasses. Adds the reflected
  # IDL boolean / string attribute helpers each subclass uses.
  class HTMLElement < Element
    private

    def reflected_boolean(name)
      @__node__.key?(name.to_s.downcase)
    end

    def set_reflected_boolean(name, value)
      key = name.to_s.downcase
      if value
        set_attribute(key, "")
      elsif @__node__.key?(key)
        remove_attribute(key)
      end
    end

    def reflected_string(name)
      @__node__[name.to_s.downcase].to_s
    end

    def set_reflected_string(name, value)
      set_attribute(name.to_s.downcase, value.to_s)
    end
  end

  # `<a>` — exposes URL-component getters/setters via the `href`
  # attribute, plus reflected `target` / `download` / `rel` / `type`.
  class HTMLAnchorElement < HTMLElement
    def target;       reflected_string("target");       end
    def target=(v);   set_reflected_string("target", v); end
    def download;     reflected_string("download");     end
    def download=(v); set_reflected_string("download", v); end
    def rel;          reflected_string("rel");          end
    def rel=(v);      set_reflected_string("rel", v);    end
    def hreflang;     reflected_string("hreflang");     end
    def type;         reflected_string("type");         end

    # URL-decomposition helpers. The anchor's `href` is resolved to
    # an absolute URL (inherited from Element#anchor_href); break it
    # into the standard components on demand.
    def hash; uri_part(:fragment) ? "##{uri_part(:fragment)}" : "";  end
    def host;     uri.host ? "#{uri.host}#{port_suffix}" : "";  end
    def hostname; uri.host || ""; end
    def pathname; uri.path || "/"; end
    def protocol; uri.scheme ? "#{uri.scheme}:" : ""; end
    def search;   uri.query ? "?#{uri.query}" : ""; end
    def port;     uri.port ? uri.port.to_s : ""; end
    def origin
      uri.scheme && uri.host ? "#{uri.scheme}://#{uri.host}#{port_suffix}" : ""
    end

    def __js_get__(key)
      case key
      when "target"   then target
      when "download" then download
      when "rel"      then rel
      when "hreflang" then hreflang
      when "type"     then type
      when "hash"     then self.hash
      when "host"     then host
      when "hostname" then hostname
      when "pathname" then pathname
      when "protocol" then protocol
      when "search"   then search
      when "port"     then port
      when "origin"   then origin
      else super
      end
    end

    def __js_set__(key, value)
      case key
      when "target", "download", "rel", "hreflang"
        set_reflected_string(key, value)
      else
        super
      end
    end

    private

    def uri
      require "uri"
      URI(anchor_href)
    rescue URI::InvalidURIError, ArgumentError
      URI("")
    end

    def uri_part(part)
      uri.send(part)
    end

    def port_suffix
      return "" unless uri.port

      default = uri.scheme == "https" ? 443 : 80
      uri.port == default ? "" : ":#{uri.port}"
    end
  end

  # `<form>` — element collection, submit/reset, and a stubbed
  # validation surface.
  class HTMLFormElement < HTMLElement
    def name;    reflected_string("name");    end
    def name=(v); set_reflected_string("name", v); end
    def action;  reflected_string("action");  end
    def action=(v); set_reflected_string("action", v); end
    def method_attr;  reflected_string("method"); end
    def method_attr=(v); set_reflected_string("method", v); end
    def enctype; reflected_string("enctype"); end
    def target;  reflected_string("target");  end
    def autocomplete; reflected_string("autocomplete"); end
    def accept_charset; reflected_string("accept-charset"); end

    def no_validate
      reflected_boolean("novalidate")
    end

    def no_validate=(v)
      set_reflected_boolean("novalidate", v)
    end

    # `form.elements` — listed elements inside the form (excludes
    # nested forms per spec; we approximate by walking
    # input/select/textarea/button/output/fieldset).
    def elements
      query_selector_all("input, select, textarea, button, output, fieldset")
    end

    def length
      elements.size
    end

    # Fires a "submit" event; returns true if not default-prevented.
    def submit
      dispatch_event(Event.new("submit", "bubbles" => true, "cancelable" => true))
    end

    def reset
      dispatch_event(Event.new("reset", "bubbles" => true, "cancelable" => true))
    end

    def request_submit(_submitter = nil)
      submit
    end

    # Walk all listed elements; the form is "valid" iff every
    # candidate control passes its own checkValidity. Dispatches a
    # non-bubbling `invalid` event on each failing control.
    def check_validity
      ok = true
      elements.each do |el|
        next unless el.respond_to?(:will_validate)
        next unless el.will_validate
        next if el.validity.valid && (el.instance_variable_get(:@custom_validity_message) || "").empty?

        # Fire invalid event on this control (matches spec).
        el.dispatch_event(Event.new("invalid", "bubbles" => false, "cancelable" => true))
        ok = false
      end
      ok
    end

    def report_validity
      check_validity
    end

    def __js_get__(key)
      case key
      when "elements"    then elements
      when "length"      then length
      when "name"        then name
      when "action"      then action
      when "method"      then method_attr
      when "enctype"     then enctype
      when "target"      then target
      when "autocomplete" then autocomplete
      when "acceptCharset" then accept_charset
      when "noValidate"  then no_validate
      else super
      end
    end

    def __js_set__(key, value)
      case key
      when "name"        then set_reflected_string("name", value)
      when "action"      then set_reflected_string("action", value)
      when "method"      then set_reflected_string("method", value)
      when "enctype"     then set_reflected_string("enctype", value)
      when "target"      then set_reflected_string("target", value)
      when "noValidate"  then set_reflected_boolean("novalidate", value)
      else super
      end
    end

    def __js_call__(method, args)
      case method
      when "submit"         then submit
      when "reset"          then reset
      when "requestSubmit"  then request_submit(args[0])
      when "checkValidity"  then check_validity
      when "reportValidity" then report_validity
      else super
      end
    end
  end

  # `<input>` — covers the most-used form control surface.
  class HTMLInputElement < HTMLElement
    def type
      raw = @__node__["type"].to_s
      raw.empty? ? "text" : raw.downcase
    end

    def type=(v); set_reflected_string("type", v); end

    def name;        reflected_string("name");        end
    def name=(v);    set_reflected_string("name", v); end
    def placeholder; reflected_string("placeholder"); end
    def placeholder=(v); set_reflected_string("placeholder", v); end
    def min;         reflected_string("min");         end
    def max;         reflected_string("max");         end
    def step;        reflected_string("step");        end
    def pattern;     reflected_string("pattern");     end
    def autocomplete; reflected_string("autocomplete"); end
    def autofocus
      reflected_boolean("autofocus")
    end
    def autofocus=(v); set_reflected_boolean("autofocus", v); end

    def default_value;     reflected_string("value");   end
    def default_checked;   reflected_boolean("checked"); end

    def labels
      return [] if id.empty?

      @document.query_selector_all("label[for='#{id}']")
    end

    # Closest enclosing form (or nil if detached / not in a form).
    def form
      closest("form")
    end

    # No real text selection; method stubs let callers proceed.
    def select; nil; end
    def set_selection_range(_start, _end, _direction = nil); nil; end
    def set_range_text(_replacement, *_); nil; end
    def step_up(_n = 1); nil; end
    def step_down(_n = 1); nil; end

    def validity
      @__validity ||= ValidityState.new(self)
    end

    # Whether this control participates in constraint validation.
    # Disabled / hidden / button-type inputs return false.
    def will_validate
      return false if reflected_boolean("disabled")
      return false if reflected_boolean("readonly")
      return false if %w[hidden button submit reset image].include?(type)

      true
    end

    def validation_message
      return "" unless will_validate

      msg = (@custom_validity_message || "").to_s
      return msg unless msg.empty?
      return "Please fill out this field." if validity.value_missing
      return "Please match the requested format." if validity.pattern_mismatch
      return "Please enter a valid email address." if validity.type_mismatch && type == "email"
      return "Please enter a URL." if validity.type_mismatch && type == "url"

      ""
    end

    def check_validity
      ok = !will_validate || validity.valid
      dispatch_event(Event.new("invalid", "bubbles" => false, "cancelable" => true)) unless ok
      ok
    end

    def report_validity
      check_validity
    end

    def set_custom_validity(msg)
      @custom_validity_message = msg.to_s
      nil
    end

    def __js_get__(key)
      case key
      when "type"          then type
      when "name"          then name
      when "placeholder"   then placeholder
      when "min"           then min
      when "max"           then max
      when "step"          then step
      when "pattern"       then pattern
      when "autocomplete"  then autocomplete
      when "autofocus"     then autofocus
      when "defaultValue"  then default_value
      when "defaultChecked" then default_checked
      when "labels"        then labels
      when "form"          then form
      when "validity"      then validity
      when "willValidate"  then will_validate
      when "validationMessage" then validation_message
      else super
      end
    end

    def __js_set__(key, value)
      case key
      when "type"         then set_reflected_string("type", value)
      when "name"         then set_reflected_string("name", value)
      when "placeholder"  then set_reflected_string("placeholder", value)
      when "min", "max", "step", "pattern", "autocomplete"
        set_reflected_string(key, value)
      when "autofocus"    then set_reflected_boolean("autofocus", value)
      else super
      end
    end

    def __js_call__(method, args)
      case method
      when "select"             then select
      when "setSelectionRange"  then set_selection_range(args[0], args[1], args[2])
      when "setRangeText"       then set_range_text(args[0])
      when "stepUp"             then step_up(args[0])
      when "stepDown"           then step_down(args[0])
      when "checkValidity"      then check_validity
      when "reportValidity"     then report_validity
      when "setCustomValidity"  then set_custom_validity(args[0])
      else super
      end
    end
  end

  # `<button>` — type defaults to "submit" per spec.
  class HTMLButtonElement < HTMLElement
    def type
      raw = @__node__["type"].to_s.downcase
      %w[submit reset button].include?(raw) ? raw : "submit"
    end

    def type=(v); set_reflected_string("type", v); end

    def name;         reflected_string("name");         end
    def name=(v);     set_reflected_string("name", v);   end
    def form_action;  reflected_string("formaction");   end
    def form_enctype; reflected_string("formenctype");  end
    def form_method;  reflected_string("formmethod");   end
    def form_target;  reflected_string("formtarget");   end

    def form_no_validate;     reflected_boolean("formnovalidate"); end
    def form_no_validate=(v); set_reflected_boolean("formnovalidate", v); end

    def form;   closest("form"); end
    def labels
      return [] if id.empty?

      @document.query_selector_all("label[for='#{id}']")
    end

    def validity
      @__validity ||= ValidityState.new(self)
    end

    # Buttons don't participate in constraint validation (per spec).
    def will_validate; false; end
    def validation_message; ""; end

    def check_validity;  true; end
    def report_validity; true; end
    def set_custom_validity(msg)
      @custom_validity_message = msg.to_s
      nil
    end

    def __js_get__(key)
      case key
      when "type"              then type
      when "name"              then name
      when "formAction"        then form_action
      when "formEnctype"       then form_enctype
      when "formMethod"        then form_method
      when "formTarget"        then form_target
      when "formNoValidate"    then form_no_validate
      when "form"              then form
      when "labels"            then labels
      when "validity"          then validity
      when "willValidate"      then will_validate
      when "validationMessage" then validation_message
      else super
      end
    end

    def __js_set__(key, value)
      case key
      when "type"           then set_reflected_string("type", value)
      when "name"           then set_reflected_string("name", value)
      when "formAction"     then set_reflected_string("formaction", value)
      when "formEnctype"    then set_reflected_string("formenctype", value)
      when "formMethod"     then set_reflected_string("formmethod", value)
      when "formTarget"     then set_reflected_string("formtarget", value)
      when "formNoValidate" then set_reflected_boolean("formnovalidate", value)
      else super
      end
    end
  end

  # `<img>` — reflected URL/dimension attributes. Dommy has no real
  # image loading, so `complete`/`naturalWidth`/`naturalHeight` are
  # static (complete=true, dimensions=0).
  class HTMLImageElement < HTMLElement
    def src;       reflected_string("src");       end
    def src=(v);   set_reflected_string("src", v); end
    def alt;       reflected_string("alt");       end
    def alt=(v);   set_reflected_string("alt", v); end
    def width;     @__node__["width"].to_s.to_i;  end
    def width=(v); set_reflected_string("width", v.to_s); end
    def height;    @__node__["height"].to_s.to_i; end
    def height=(v); set_reflected_string("height", v.to_s); end
    def crossorigin; reflected_string("crossorigin"); end
    def decoding;    reflected_string("decoding");    end
    def loading;     reflected_string("loading");     end
    def referrer_policy; reflected_string("referrerpolicy"); end
    def sizes;       reflected_string("sizes");       end
    def srcset;      reflected_string("srcset");      end

    # No real loader → these are constants.
    def natural_width;  0;  end
    def natural_height; 0;  end
    def complete;       true; end
    def current_src;    src;  end

    def __js_get__(key)
      case key
      when "src"           then src
      when "alt"           then alt
      when "width"         then width
      when "height"        then height
      when "naturalWidth"  then natural_width
      when "naturalHeight" then natural_height
      when "complete"      then complete
      when "currentSrc"    then current_src
      when "crossOrigin"   then crossorigin
      when "decoding"      then decoding
      when "loading"       then loading
      when "referrerPolicy" then referrer_policy
      when "sizes"         then sizes
      when "srcset"        then srcset
      else super
      end
    end

    def __js_set__(key, value)
      case key
      when "src", "alt", "decoding", "loading", "sizes", "srcset"
        set_reflected_string(key, value)
      when "width", "height"
        set_reflected_string(key, value.to_s)
      when "crossOrigin"    then set_reflected_string("crossorigin", value)
      when "referrerPolicy" then set_reflected_string("referrerpolicy", value)
      else super
      end
    end
  end

  # `<script>` — `src` / `type` / `async` / `defer` / `text`.
  class HTMLScriptElement < HTMLElement
    def src;       reflected_string("src");       end
    def src=(v);   set_reflected_string("src", v); end
    def type;      reflected_string("type");      end
    def type=(v);  set_reflected_string("type", v); end
    def integrity; reflected_string("integrity"); end
    def nonce;     reflected_string("nonce");     end
    def referrer_policy; reflected_string("referrerpolicy"); end
    def async
      reflected_boolean("async")
    end
    def async=(v); set_reflected_boolean("async", v); end
    def defer
      reflected_boolean("defer")
    end
    def defer=(v); set_reflected_boolean("defer", v); end
    def no_module
      reflected_boolean("nomodule")
    end
    def no_module=(v); set_reflected_boolean("nomodule", v); end

    # `text` is an alias for textContent on <script>.
    def text;     text_content; end
    def text=(v); self.text_content = v; end

    def __js_get__(key)
      case key
      when "src"           then src
      when "type"          then type
      when "async"         then async
      when "defer"         then defer
      when "noModule"      then no_module
      when "integrity"     then integrity
      when "nonce"         then nonce
      when "referrerPolicy" then referrer_policy
      when "text"          then text
      else super
      end
    end

    def __js_set__(key, value)
      case key
      when "src", "type", "integrity", "nonce"
        set_reflected_string(key, value)
      when "async"          then set_reflected_boolean("async", value)
      when "defer"          then set_reflected_boolean("defer", value)
      when "noModule"       then set_reflected_boolean("nomodule", value)
      when "referrerPolicy" then set_reflected_string("referrerpolicy", value)
      when "text"           then self.text_content = value
      else super
      end
    end
  end

  # `<link>` — primarily for stylesheets, icons, preload, manifests.
  class HTMLLinkElement < HTMLElement
    def href;     reflected_string("href");      end
    def href=(v); set_reflected_string("href", v); end
    def rel;      reflected_string("rel");       end
    def rel=(v);  set_reflected_string("rel", v); end
    def type;     reflected_string("type");      end
    def type=(v); set_reflected_string("type", v); end
    def media;    reflected_string("media");     end
    def sizes;    reflected_string("sizes");     end
    def hreflang; reflected_string("hreflang");  end
    def as_attr;  reflected_string("as");        end
    def crossorigin; reflected_string("crossorigin"); end
    def integrity; reflected_string("integrity"); end
    def referrer_policy; reflected_string("referrerpolicy"); end

    def __js_get__(key)
      case key
      when "href"          then href
      when "rel"           then rel
      when "type"          then type
      when "media"         then media
      when "sizes"         then sizes
      when "hreflang"      then hreflang
      when "as"            then as_attr
      when "crossOrigin"   then crossorigin
      when "integrity"     then integrity
      when "referrerPolicy" then referrer_policy
      else super
      end
    end

    def __js_set__(key, value)
      case key
      when "href", "rel", "type", "media", "sizes", "hreflang", "as", "integrity"
        set_reflected_string(key, value)
      when "crossOrigin"    then set_reflected_string("crossorigin", value)
      when "referrerPolicy" then set_reflected_string("referrerpolicy", value)
      else super
      end
    end
  end

  # `ValidityState` — computes constraint-validation flags from the
  # host control's current attributes and value. Bound to a single
  # host control; reads dynamically on every access so attribute
  # changes between calls are reflected.
  #
  # Flags follow the HTML spec; `badInput` is always false (we'd need
  # the browser's number parser to detect "12abc" in a type=number).
  class ValidityState
    FLAGS = %w[
      valueMissing typeMismatch patternMismatch tooLong tooShort
      rangeUnderflow rangeOverflow stepMismatch badInput customError
    ].freeze

    EMAIL_RE = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/
    URL_SCHEMES = %w[http:// https:// ftp://].freeze

    def initialize(host = nil)
      @host = host
    end

    # ---- Computed flags ----

    def value_missing
      return false unless @host && host_attr_present?("required")

      case host_type
      when "checkbox", "radio"
        !host_attr_present?("checked")
      else
        host_value.to_s.empty?
      end
    end

    def type_mismatch
      return false unless @host

      v = host_value.to_s
      return false if v.empty?

      case host_type
      when "email" then !v.match?(EMAIL_RE)
      when "url"   then URL_SCHEMES.none? { |s| v.start_with?(s) }
      else false
      end
    end

    def pattern_mismatch
      return false unless @host

      pat = host_attr_value("pattern").to_s
      return false if pat.empty?

      v = host_value.to_s
      return false if v.empty?

      !Regexp.new("\\A(?:#{pat})\\z").match?(v)
    rescue RegexpError
      false
    end

    def too_long
      return false unless @host

      max = host_attr_value("maxlength").to_s
      return false if max.empty?

      max_n = max.to_i
      return false if max_n < 0

      host_value.to_s.length > max_n
    end

    def too_short
      return false unless @host

      min = host_attr_value("minlength").to_s
      return false if min.empty?

      min_n = min.to_i
      return false if min_n < 0

      v = host_value.to_s
      !v.empty? && v.length < min_n
    end

    def range_underflow
      return false unless numeric_host?

      min = host_attr_value("min").to_s
      return false if min.empty?

      num = numeric_value
      num && num < min.to_f
    end

    def range_overflow
      return false unless numeric_host?

      max = host_attr_value("max").to_s
      return false if max.empty?

      num = numeric_value
      num && num > max.to_f
    end

    def step_mismatch
      return false unless numeric_host?

      step = host_attr_value("step").to_s
      return false if step.empty? || step == "any"

      step_n = step.to_f
      return false if step_n <= 0

      num = numeric_value
      return false unless num

      base = host_attr_value("min").to_s
      base_n = base.empty? ? 0.0 : base.to_f
      ((num - base_n) / step_n - ((num - base_n) / step_n).round).abs > 1e-9
    end

    def bad_input
      false
    end

    def custom_error
      !custom_message.empty?
    end

    def valid
      !(value_missing || type_mismatch || pattern_mismatch ||
        too_long || too_short || range_underflow || range_overflow ||
        step_mismatch || bad_input || custom_error)
    end

    # ---- Bridge protocol ----

    def __js_get__(key)
      case key
      when "valueMissing"    then value_missing
      when "typeMismatch"    then type_mismatch
      when "patternMismatch" then pattern_mismatch
      when "tooLong"         then too_long
      when "tooShort"        then too_short
      when "rangeUnderflow"  then range_underflow
      when "rangeOverflow"   then range_overflow
      when "stepMismatch"    then step_mismatch
      when "badInput"        then bad_input
      when "customError"     then custom_error
      when "valid"           then valid
      end
    end

    private

    def host_value
      return "" unless @host

      @host.respond_to?(:value) ? @host.value : @host.__js_get__("value")
    end

    def host_attr_value(name)
      return "" unless @host

      @host.__node__[name].to_s
    end

    def host_attr_present?(name)
      return false unless @host

      @host.__node__.key?(name.to_s)
    end

    def host_type
      return nil unless @host

      @host.respond_to?(:type) ? @host.type : ""
    end

    def custom_message
      return "" unless @host

      (@host.instance_variable_get(:@custom_validity_message) || "").to_s
    end

    def numeric_host?
      @host.is_a?(HTMLInputElement) && %w[number range].include?(host_type)
    end

    def numeric_value
      v = host_value.to_s
      return nil if v.empty?

      Float(v)
    rescue ArgumentError
      nil
    end

    def truthy?(value)
      v = value.to_s
      !v.empty? && v != "false" && v != "0"
    end
  end

  # `<option>` — value, label, selected, disabled, text, index, form.
  class HTMLOptionElement < HTMLElement
    def value
      # Per spec, value defaults to text content if the `value`
      # attribute is absent.
      @__node__.key?("value") ? @__node__["value"].to_s : text_content
    end

    def value=(v)
      set_reflected_string("value", v)
    end

    def label
      @__node__.key?("label") ? @__node__["label"].to_s : text_content
    end

    def label=(v); set_reflected_string("label", v); end

    def selected
      reflected_boolean("selected")
    end

    def selected=(v)
      set_reflected_boolean("selected", v)
    end

    def default_selected;     selected;             end
    def default_selected=(v); self.selected = v;     end

    def disabled
      reflected_boolean("disabled")
    end

    def disabled=(v); set_reflected_boolean("disabled", v); end

    def text;     text_content;  end
    def text=(v); self.text_content = v; end

    def form;  closest("form"); end

    # `index` — position within the containing select's options list.
    def index
      sel = closest("select")
      return 0 unless sel

      sel.options.find_index { |o| o.__node__ == @__node__ } || 0
    end

    def __js_get__(key)
      case key
      when "value"           then value
      when "label"           then label
      when "selected"        then selected
      when "defaultSelected" then default_selected
      when "disabled"        then disabled
      when "text"            then text
      when "form"            then form
      when "index"           then index
      else super
      end
    end

    def __js_set__(key, v)
      case key
      when "value"           then self.value = v
      when "label"           then self.label = v
      when "selected", "defaultSelected" then self.selected = v
      when "disabled"        then self.disabled = v
      when "text"            then self.text = v
      else super
      end
    end
  end

  # `<optgroup>` — label + disabled, container for options.
  class HTMLOptGroupElement < HTMLElement
    def label;     reflected_string("label");     end
    def label=(v); set_reflected_string("label", v); end
    def disabled
      reflected_boolean("disabled")
    end
    def disabled=(v); set_reflected_boolean("disabled", v); end

    def __js_get__(key)
      case key
      when "label"    then label
      when "disabled" then disabled
      else super
      end
    end

    def __js_set__(key, v)
      case key
      when "label"    then self.label = v
      when "disabled" then self.disabled = v
      else super
      end
    end
  end

  # `<textarea>` — multi-line text input.
  class HTMLTextAreaElement < HTMLElement
    def value
      @__node__["value"] || text_content
    end

    def value=(v)
      @__node__["value"] = v.to_s
      self.text_content = v.to_s
    end

    def default_value;     text_content;        end
    def default_value=(v); self.text_content = v; end

    def name;        reflected_string("name");        end
    def name=(v);    set_reflected_string("name", v); end
    def placeholder; reflected_string("placeholder"); end
    def placeholder=(v); set_reflected_string("placeholder", v); end
    def rows;        (@__node__["rows"] || "2").to_i; end
    def rows=(v);    set_reflected_string("rows", v.to_s); end
    def cols;        (@__node__["cols"] || "20").to_i; end
    def cols=(v);    set_reflected_string("cols", v.to_s); end
    def wrap;        reflected_string("wrap");        end
    def max_length;  (@__node__["maxlength"] || "-1").to_i; end
    def min_length;  (@__node__["minlength"] || "-1").to_i; end
    def text_length; value.length;                  end
    def autocomplete; reflected_string("autocomplete"); end

    def type; "textarea"; end

    def form;  closest("form"); end

    def labels
      return [] if id.empty?

      @document.query_selector_all("label[for='#{id}']")
    end

    # No real selection — same stub story as input.
    def select; nil; end
    def set_selection_range(_s, _e, _direction = nil); nil; end
    def set_range_text(_replacement, *_); nil; end

    def validity
      @__validity ||= ValidityState.new(self)
    end

    def will_validate
      !reflected_boolean("disabled") && !reflected_boolean("readonly")
    end

    def validation_message
      return "" unless will_validate

      msg = (@custom_validity_message || "").to_s
      return msg unless msg.empty?
      return "Please fill out this field." if validity.value_missing

      ""
    end

    def check_validity
      ok = !will_validate || validity.valid
      dispatch_event(Event.new("invalid", "bubbles" => false, "cancelable" => true)) unless ok
      ok
    end

    def report_validity;   check_validity; end

    def set_custom_validity(msg)
      @custom_validity_message = msg.to_s
      nil
    end

    def __js_get__(key)
      case key
      when "value"             then value
      when "defaultValue"      then default_value
      when "name"              then name
      when "placeholder"       then placeholder
      when "rows"              then rows
      when "cols"              then cols
      when "wrap"              then wrap
      when "maxLength"         then max_length
      when "minLength"         then min_length
      when "textLength"        then text_length
      when "autocomplete"      then autocomplete
      when "type"              then type
      when "form"              then form
      when "labels"            then labels
      when "validity"          then validity
      when "willValidate"      then will_validate
      when "validationMessage" then validation_message
      else super
      end
    end

    def __js_set__(key, v)
      case key
      when "value"         then self.value = v
      when "defaultValue"  then self.default_value = v
      when "name"          then set_reflected_string("name", v)
      when "placeholder"   then set_reflected_string("placeholder", v)
      when "rows"          then self.rows = v
      when "cols"          then self.cols = v
      when "wrap"          then set_reflected_string("wrap", v)
      when "maxLength"     then set_reflected_string("maxlength", v.to_s)
      when "minLength"     then set_reflected_string("minlength", v.to_s)
      else super
      end
    end

    def __js_call__(method, args)
      case method
      when "select"             then select
      when "setSelectionRange"  then set_selection_range(args[0], args[1], args[2])
      when "setRangeText"       then set_range_text(args[0])
      when "checkValidity"      then check_validity
      when "reportValidity"     then report_validity
      when "setCustomValidity"  then set_custom_validity(args[0])
      else super
      end
    end
  end  # end HTMLTextAreaElement

  # `<label>` — `htmlFor` IDL maps to the HTML `for` attribute;
  # `control` returns the labelled form control.
  class HTMLLabelElement < HTMLElement
    def html_for;     reflected_string("for");        end
    def html_for=(v); set_reflected_string("for", v); end

    # `label.control` — the form control associated with this label.
    # Priority: explicit `for=`, then first form control descendant.
    def control
      target = html_for
      if !target.empty?
        @document.get_element_by_id(target)
      else
        query_selector("input, select, textarea, button, output, meter, progress")
      end
    end

    def form;  closest("form"); end

    def __js_get__(key)
      case key
      when "htmlFor" then html_for
      when "control" then control
      when "form"    then form
      else super
      end
    end

    def __js_set__(key, v)
      case key
      when "htmlFor" then self.html_for = v
      else super
      end
    end
  end

  # `<fieldset>` — disabled-state-propagating wrapper; exposes
  # `elements` collection like form.
  class HTMLFieldsetElement < HTMLElement
    def name;     reflected_string("name");     end
    def name=(v); set_reflected_string("name", v); end
    def disabled
      reflected_boolean("disabled")
    end
    def disabled=(v); set_reflected_boolean("disabled", v); end

    def type; "fieldset"; end
    def form; closest("form"); end

    def elements
      query_selector_all("input, select, textarea, button, output, fieldset")
    end

    def validity;        ValidityState.new; end
    def check_validity;  true; end
    def report_validity; true; end

    def __js_get__(key)
      case key
      when "name"     then name
      when "disabled" then disabled
      when "type"     then type
      when "form"     then form
      when "elements" then elements
      when "validity" then validity
      else super
      end
    end

    def __js_set__(key, v)
      case key
      when "name"     then self.name = v
      when "disabled" then self.disabled = v
      else super
      end
    end
  end

  # `<output>` — calculation result element.
  class HTMLOutputElement < HTMLElement
    def value;     text_content;          end
    def value=(v); self.text_content = v; end
    def default_value;     text_content;          end
    def default_value=(v); self.text_content = v; end
    def name;      reflected_string("name");        end
    def name=(v);  set_reflected_string("name", v); end

    # `for` attribute is a space-separated list of IDs.
    def html_for_tokens
      reflected_string("for").split(/\s+/).reject(&:empty?)
    end

    def form;  closest("form"); end
    def labels
      return [] if id.empty?

      @document.query_selector_all("label[for='#{id}']")
    end

    def type; "output"; end
    def validity;        ValidityState.new; end
    def check_validity;  true; end
    def report_validity; true; end

    def __js_get__(key)
      case key
      when "value"        then value
      when "defaultValue" then default_value
      when "name"         then name
      when "type"         then type
      when "form"         then form
      when "labels"       then labels
      when "validity"     then validity
      when "htmlFor"      then reflected_string("for")
      else super
      end
    end

    def __js_set__(key, v)
      case key
      when "value"        then self.value = v
      when "defaultValue" then self.default_value = v
      when "name"         then self.name = v
      when "htmlFor"      then set_reflected_string("for", v)
      else super
      end
    end
  end

  # `<legend>` — primarily exposes its `form` back-ref.
  class HTMLLegendElement < HTMLElement
    def form
      fieldset = closest("fieldset")
      fieldset&.closest("form") || closest("form")
    end

    def __js_get__(key)
      key == "form" ? form : super
    end
  end

  # `<slot>` — composes light DOM into the shadow tree. Light DOM
  # children of the shadow's host get assigned to slots: those whose
  # `slot=name` attribute matches a named slot, or those without a
  # `slot` attribute go to the unnamed default slot. If nothing is
  # assigned, the slot's own children render as fallback content.
  class HTMLSlotElement < HTMLElement
    def name;     reflected_string("name");        end
    def name=(v); set_reflected_string("name", v); end

    # `slot.assignedNodes({ flatten: true|false })` — returns the
    # light DOM children currently composed into this slot. With
    # `flatten: true` and no assigned nodes, falls back to the
    # slot's own children (the default content).
    def assigned_nodes(options = nil)
      flatten = options.is_a?(Hash) ? (options["flatten"] || options[:flatten]) : false
      nodes = matching_light_nodes
      if nodes.empty? && flatten
        @__node__.children.map { |n| @document.wrap_node(n) }.compact
      else
        nodes
      end
    end

    def assigned_elements(options = nil)
      assigned_nodes(options).select { |n| n.is_a?(Element) }
    end

    # `slot.assign(...)` — manual assignment (honored only when the
    # owning shadow uses `slotAssignment: "manual"`). We accept the
    # call and fire `slotchange` in both modes; named mode simply
    # ignores the override.
    def assign(*nodes)
      @__manual_assignment = nodes.flatten.select { |n| n.respond_to?(:__node__) }
      dispatch_event(Event.new("slotchange", "bubbles" => true))
      nil
    end

    def __js_get__(key)
      case key
      when "name"             then name
      when "assignedNodes"    then assigned_nodes
      when "assignedElements" then assigned_elements
      else super
      end
    end

    def __js_set__(key, value)
      case key
      when "name" then self.name = value
      else super
      end
    end

    def __js_call__(method, args)
      case method
      when "assignedNodes"    then assigned_nodes(args[0])
      when "assignedElements" then assigned_elements(args[0])
      when "assign"           then assign(*args)
      else super
      end
    end

    private

    def matching_light_nodes
      sr = @document.__shadow_root_containing__(@__node__)
      return [] unless sr

      host = sr.host
      return [] unless host

      slot_name = name
      # Manual mode honors the explicit list.
      if sr.slot_assignment == "manual" && @__manual_assignment
        return @__manual_assignment
      end

      host.__node__.children.map do |child|
        wrapped = @document.wrap_node(child)
        next nil unless wrapped

        attr_value = child.element? ? child["slot"].to_s : ""
        if slot_name.empty?
          attr_value.empty? ? wrapped : nil
        else
          (child.element? && attr_value == slot_name) ? wrapped : nil
        end
      end.compact
    end
  end

  # `<select>` — exposes `value` (selected option's value), `options`,
  # `selectedIndex`, and dispatches change events. Minimal compared to
  # happy-dom's full HTMLSelectElement, but covers common test cases.
  class HTMLSelectElement < HTMLElement
    def name;      reflected_string("name");        end
    def name=(v);  set_reflected_string("name", v); end
    def multiple
      reflected_boolean("multiple")
    end
    def multiple=(v); set_reflected_boolean("multiple", v); end
    def size;      @__node__["size"].to_s.to_i;     end

    # `options` — all <option> descendants (including those inside
    # <optgroup>).
    def options
      query_selector_all("option")
    end

    def length
      options.size
    end

    def form;   closest("form"); end

    # `selectedIndex` — first option with `selected`, or 0 if none and
    # not multiple, or -1 if multiple and none.
    def selected_index
      opts = options
      idx = opts.find_index { |o| o.__node__.key?("selected") }
      return idx if idx

      multiple ? -1 : (opts.empty? ? -1 : 0)
    end

    def selected_index=(i)
      opts = options
      opts.each_with_index do |o, idx|
        if idx == i.to_i
          o.set_attribute("selected", "")
        elsif o.__node__.key?("selected")
          o.remove_attribute("selected")
        end
      end
    end

    # `value` of the select = value of the selected option, or "".
    def value
      opts = options
      sel = opts.find { |o| o.__node__.key?("selected") } || opts.first
      sel ? (sel.__node__["value"] || sel.text_content).to_s : ""
    end

    def value=(new_value)
      target = options.find { |o| (o.__node__["value"] || o.text_content).to_s == new_value.to_s }
      return unless target

      options.each { |o| o.remove_attribute("selected") if o.__node__.key?("selected") }
      target.set_attribute("selected", "")
    end

    # `select.item(i)` — returns the option at index i.
    def item(i)
      options[i.to_i]
    end

    # `select.add(option, before)` — appends or inserts before `before`.
    def add(option, before = nil)
      return nil unless option.respond_to?(:__node__)

      if before.respond_to?(:__node__)
        insert_before(option, before)
      else
        append_child(option)
      end
      nil
    end

    # `select.remove(i)` — removes the option at index i. (Note: also
    # inherits `remove()` from ChildNode for self-removal; spec lets
    # both forms coexist via overloading.)
    def remove_option(i)
      target = options[i.to_i]
      target&.remove
    end

    def labels
      return [] if id.empty?

      @document.query_selector_all("label[for='#{id}']")
    end

    def type
      multiple ? "select-multiple" : "select-one"
    end

    def validity
      @__validity ||= ValidityState.new(self)
    end

    def will_validate
      !reflected_boolean("disabled")
    end

    def validation_message
      return "" unless will_validate

      msg = (@custom_validity_message || "").to_s
      return msg unless msg.empty?
      return "Please select an item in the list." if validity.value_missing

      ""
    end

    def check_validity
      ok = !will_validate || validity.valid
      dispatch_event(Event.new("invalid", "bubbles" => false, "cancelable" => true)) unless ok
      ok
    end

    def report_validity; check_validity; end

    def set_custom_validity(msg)
      @custom_validity_message = msg.to_s
      nil
    end

    def __js_get__(key)
      case key
      when "options"           then options
      when "length"            then length
      when "value"             then value
      when "name"              then name
      when "multiple"          then multiple
      when "size"              then size
      when "selectedIndex"     then selected_index
      when "form"              then form
      when "labels"            then labels
      when "type"              then type
      when "validity"          then validity
      when "willValidate"      then will_validate
      when "validationMessage" then validation_message
      else super
      end
    end

    def __js_set__(key, val)
      case key
      when "value"          then self.value = val
      when "name"           then set_reflected_string("name", val)
      when "multiple"       then set_reflected_boolean("multiple", val)
      when "selectedIndex"  then self.selected_index = val
      else super
      end
    end

    def __js_call__(method, args)
      case method
      when "item"               then item(args[0])
      when "add"                then add(args[0], args[1])
      when "checkValidity"      then check_validity
      when "reportValidity"     then report_validity
      when "setCustomValidity"  then set_custom_validity(args[0])
      else super
      end
    end
  end

  # `<dialog>` — `open` reflected boolean, `show()` / `showModal()` /
  # `close(returnValue?)`. Dommy has no modal stack, so showModal is
  # functionally identical to show (no backdrop, no escape-to-close).
  class HTMLDialogElement < HTMLElement
    def open
      reflected_boolean("open")
    end

    def open=(v)
      set_reflected_boolean("open", v)
    end

    def return_value
      @return_value ||= ""
    end

    def return_value=(v)
      @return_value = v.to_s
    end

    def show
      self.open = true
      nil
    end

    def show_modal
      self.open = true
      nil
    end

    def close(value = nil)
      self.open = false
      @return_value = value.to_s unless value.nil?
      dispatch_event(Event.new("close", "bubbles" => false, "cancelable" => false))
      nil
    end

    def __js_get__(key)
      case key
      when "open"        then open
      when "returnValue" then return_value
      else super
      end
    end

    def __js_set__(key, value)
      case key
      when "open"        then self.open = value
      when "returnValue" then self.return_value = value
      else super
      end
    end

    def __js_call__(method, args)
      case method
      when "show"      then show
      when "showModal" then show_modal
      when "close"     then close(args[0])
      else super
      end
    end
  end

  # `<details>` — `open` reflected boolean. Toggling it fires a
  # `toggle` event (non-bubbling per spec).
  class HTMLDetailsElement < HTMLElement
    def open
      reflected_boolean("open")
    end

    def open=(v)
      was = open
      set_reflected_boolean("open", v)
      now = open
      return if was == now

      dispatch_event(Event.new("toggle", "bubbles" => false, "cancelable" => false))
    end

    def __js_get__(key)
      key == "open" ? open : super
    end

    def __js_set__(key, value)
      if key == "open"
        self.open = value
      else
        super
      end
    end
  end

  # `<meter>` — gauge with `value` / `min` / `max` (default 0/0/1)
  # plus `low` / `high` / `optimum`. All numeric; `labels` via the
  # standard `<label for="...">` association.
  class HTMLMeterElement < HTMLElement
    def value;     numeric_attr("value", 0.0); end
    def value=(v); set_reflected_string("value", v.to_s); end
    def min;       numeric_attr("min", 0.0); end
    def min=(v);   set_reflected_string("min", v.to_s); end
    def max;       numeric_attr("max", 1.0); end
    def max=(v);   set_reflected_string("max", v.to_s); end
    def low;       numeric_attr("low", min); end
    def low=(v);   set_reflected_string("low", v.to_s); end
    def high;      numeric_attr("high", max); end
    def high=(v);  set_reflected_string("high", v.to_s); end
    def optimum;   numeric_attr("optimum", (min + max) / 2.0); end
    def optimum=(v); set_reflected_string("optimum", v.to_s); end

    def labels
      return [] if id.empty?

      @document.query_selector_all("label[for='#{id}']")
    end

    def __js_get__(key)
      case key
      when "value"   then value
      when "min"     then min
      when "max"     then max
      when "low"     then low
      when "high"    then high
      when "optimum" then optimum
      when "labels"  then labels
      else super
      end
    end

    def __js_set__(key, v)
      case key
      when "value", "min", "max", "low", "high", "optimum"
        set_reflected_string(key, v.to_s)
      else super
      end
    end

    private

    def numeric_attr(name, default)
      raw = @__node__[name].to_s
      raw.empty? ? default : Float(raw) rescue default
    end
  end

  # `<progress>` — `value` and `max` (default max=1). `position`
  # returns `value / max` for a "determinate" progress bar, or -1
  # when no value is set ("indeterminate").
  class HTMLProgressElement < HTMLElement
    def value
      raw = @__node__["value"].to_s
      raw.empty? ? nil : Float(raw)
    rescue ArgumentError
      nil
    end

    def value=(v); set_reflected_string("value", v.to_s); end

    def max
      raw = @__node__["max"].to_s
      raw.empty? ? 1.0 : (Float(raw) rescue 1.0)
    end

    def max=(v); set_reflected_string("max", v.to_s); end

    # `position` = value/max for determinate progress; -1 if value
    # was never set (indeterminate).
    def position
      v = value
      return -1.0 if v.nil?

      m = max
      m <= 0 ? 1.0 : (v / m)
    end

    def labels
      return [] if id.empty?

      @document.query_selector_all("label[for='#{id}']")
    end

    def __js_get__(key)
      case key
      when "value"    then value
      when "max"      then max
      when "position" then position
      when "labels"   then labels
      else super
      end
    end

    def __js_set__(key, v)
      case key
      when "value", "max" then set_reflected_string(key, v.to_s)
      else super
      end
    end
  end

  # `<template>` — `content` returns the DocumentFragment that
  # owns the template's children. Reuses the document-level
  # template_content storage so existing template handling stays
  # consistent.
  class HTMLTemplateElement < HTMLElement
    def content
      @document.template_content_fragment(self)
    end

    def __js_get__(key)
      case key
      when "content" then content
      else super
      end
    end
  end

  # `<td>` / `<th>` — single table cell. `cellIndex` is the
  # position within the parent row's cells collection.
  class HTMLTableCellElement < HTMLElement
    def cell_index
      row = closest("tr")
      return -1 unless row

      row.cells.find_index { |c| c.__node__ == @__node__ } || -1
    end

    def col_span
      (@__node__["colspan"] || "1").to_i
    end

    def col_span=(v)
      set_reflected_string("colspan", v.to_s)
    end

    def row_span
      (@__node__["rowspan"] || "1").to_i
    end

    def row_span=(v)
      set_reflected_string("rowspan", v.to_s)
    end

    def headers;     reflected_string("headers");     end
    def headers=(v); set_reflected_string("headers", v); end

    # `scope` / `abbr` are only meaningful on `<th>`, but the IDL
    # exposes them on the cell element either way.
    def scope;       reflected_string("scope");       end
    def scope=(v);   set_reflected_string("scope", v); end
    def abbr;        reflected_string("abbr");        end
    def abbr=(v);    set_reflected_string("abbr", v); end

    def __js_get__(key)
      case key
      when "cellIndex" then cell_index
      when "colSpan"   then col_span
      when "rowSpan"   then row_span
      when "headers"   then headers
      when "scope"     then scope
      when "abbr"      then abbr
      else super
      end
    end

    def __js_set__(key, value)
      case key
      when "colSpan"  then self.col_span = value
      when "rowSpan"  then self.row_span = value
      when "headers"  then self.headers  = value
      when "scope"    then self.scope    = value
      when "abbr"     then self.abbr     = value
      else super
      end
    end
  end

  # `<tr>` — table row. `cells` are direct `<td>`/`<th>` children.
  # `rowIndex` walks the enclosing table; `sectionRowIndex` walks
  # the enclosing thead/tbody/tfoot.
  class HTMLTableRowElement < HTMLElement
    def cells
      @__node__.element_children.select { |n| %w[td th].include?(n.name) }
              .map { |n| @document.wrap_node(n) }.compact
    end

    def row_index
      table = closest("table")
      return -1 unless table

      table.rows.find_index { |r| r.__node__ == @__node__ } || -1
    end

    def section_row_index
      section = @__node__.parent
      return -1 unless section && section.element? && %w[thead tbody tfoot].include?(section.name)

      section.element_children.select { |n| n.name == "tr" }.find_index { |n| n == @__node__ } || -1
    end

    # `insertCell(index)` — adds a `<td>` at the given index
    # (defaults to end). Returns the new cell.
    def insert_cell(index = -1)
      cell = @document.create_element("td")
      list = cells
      if index.to_i == -1 || index.to_i >= list.size
        append_child(cell)
      else
        insert_before(cell, list[index.to_i])
      end
      cell
    end

    def delete_cell(index)
      target = cells[index.to_i]
      target&.remove
      nil
    end

    def __js_get__(key)
      case key
      when "cells"           then cells
      when "rowIndex"        then row_index
      when "sectionRowIndex" then section_row_index
      else super
      end
    end

    def __js_call__(method, args)
      case method
      when "insertCell" then insert_cell(args[0] || -1)
      when "deleteCell" then delete_cell(args[0])
      else super
      end
    end
  end

  # `<thead>` / `<tbody>` / `<tfoot>` — share section-level row
  # collection + insertRow / deleteRow.
  class HTMLTableSectionElement < HTMLElement
    def rows
      @__node__.element_children.select { |n| n.name == "tr" }
              .map { |n| @document.wrap_node(n) }.compact
    end

    def insert_row(index = -1)
      tr = @document.create_element("tr")
      list = rows
      if index.to_i == -1 || index.to_i >= list.size
        append_child(tr)
      else
        insert_before(tr, list[index.to_i])
      end
      tr
    end

    def delete_row(index)
      rows[index.to_i]&.remove
      nil
    end

    def __js_get__(key)
      key == "rows" ? rows : super
    end

    def __js_call__(method, args)
      case method
      when "insertRow" then insert_row(args[0] || -1)
      when "deleteRow" then delete_row(args[0])
      else super
      end
    end
  end

  # `<caption>` — table caption, minimal subclass.
  class HTMLTableCaptionElement < HTMLElement
  end

  # `<table>` — top-level table element. `rows` returns rows from
  # all sections (thead → tbody → tfoot); `tBodies` is a list of
  # tbody elements. `insertRow(-1)` appends to the last tbody (or
  # creates one); `deleteRow` works against the merged `rows` list.
  class HTMLTableElement < HTMLElement
    def caption
      @__node__.element_children.find { |n| n.name == "caption" }&.then { |n| @document.wrap_node(n) }
    end

    def caption=(new_caption)
      delete_caption
      return unless new_caption.respond_to?(:__node__)

      first = @__node__.children.first
      first ? first.add_previous_sibling(new_caption.__node__) : @__node__.add_child(new_caption.__node__)
    end

    def t_head
      @__node__.element_children.find { |n| n.name == "thead" }&.then { |n| @document.wrap_node(n) }
    end

    def t_foot
      @__node__.element_children.find { |n| n.name == "tfoot" }&.then { |n| @document.wrap_node(n) }
    end

    def t_bodies
      @__node__.element_children.select { |n| n.name == "tbody" }.map { |n| @document.wrap_node(n) }.compact
    end

    def rows
      ordered = []
      head = @__node__.element_children.find { |n| n.name == "thead" }
      bodies = @__node__.element_children.select { |n| n.name == "tbody" }
      direct = @__node__.element_children.select { |n| n.name == "tr" }
      foot = @__node__.element_children.find { |n| n.name == "tfoot" }
      [head, *bodies, foot].compact.each do |sec|
        sec.element_children.select { |n| n.name == "tr" }.each { |n| ordered << n }
      end
      direct.each { |n| ordered << n }
      ordered.map { |n| @document.wrap_node(n) }.compact
    end

    def create_caption
      existing = caption
      return existing if existing

      cap = @document.create_element("caption")
      first = @__node__.children.first
      first ? first.add_previous_sibling(cap.__node__) : @__node__.add_child(cap.__node__)
      cap
    end

    def delete_caption
      cap = caption
      cap&.remove
      nil
    end

    def create_t_head
      existing = t_head
      return existing if existing

      head = @document.create_element("thead")
      cap = caption
      if cap
        cap.__node__.add_next_sibling(head.__node__)
      else
        first = @__node__.children.first
        first ? first.add_previous_sibling(head.__node__) : @__node__.add_child(head.__node__)
      end
      head
    end

    def delete_t_head
      t_head&.remove
      nil
    end

    def create_t_foot
      existing = t_foot
      return existing if existing

      foot = @document.create_element("tfoot")
      @__node__.add_child(foot.__node__)
      foot
    end

    def delete_t_foot
      t_foot&.remove
      nil
    end

    def create_t_body
      tb = @document.create_element("tbody")
      last_tbody = t_bodies.last
      if last_tbody
        last_tbody.__node__.add_next_sibling(tb.__node__)
      else
        @__node__.add_child(tb.__node__)
      end
      tb
    end

    # `table.insertRow(index)` — inserts a `<tr>` at the merged
    # index. Per spec, if no `<tbody>` exists and the table is
    # empty, the row is inserted directly; otherwise it goes into
    # the last `<tbody>`.
    def insert_row(index = -1)
      list = rows
      idx = index.to_i
      idx = list.size if idx == -1 || idx > list.size

      raise "IndexSizeError" if idx < 0 || idx > list.size

      tr = @document.create_element("tr")
      if idx == list.size
        target_section = t_bodies.last || create_t_body
        target_section.append_child(tr)
      else
        anchor = list[idx]
        section = anchor.__node__.parent
        if section
          anchor.__node__.add_previous_sibling(tr.__node__)
          @document.notify_child_list_mutation(target_node: section, added_nodes: [tr.__node__], removed_nodes: [])
        end
      end
      tr
    end

    def delete_row(index)
      rows[index.to_i]&.remove
      nil
    end

    def __js_get__(key)
      case key
      when "caption" then caption
      when "tHead"   then t_head
      when "tFoot"   then t_foot
      when "tBodies" then t_bodies
      when "rows"    then rows
      else super
      end
    end

    def __js_set__(key, value)
      case key
      when "caption" then self.caption = value
      else super
      end
    end

    def __js_call__(method, args)
      case method
      when "insertRow"     then insert_row(args[0] || -1)
      when "deleteRow"     then delete_row(args[0])
      when "createCaption" then create_caption
      when "deleteCaption" then delete_caption
      when "createTHead"   then create_t_head
      when "deleteTHead"   then delete_t_head
      when "createTFoot"   then create_t_foot
      when "deleteTFoot"   then delete_t_foot
      when "createTBody"   then create_t_body
      else super
      end
    end
  end

  # Look up the subclass for a given HTML tag. Document#wrap_node
  # consults this map; defaults to plain Element.
  HTML_ELEMENT_CLASSES = {
    "a"        => HTMLAnchorElement,
    "form"     => HTMLFormElement,
    "input"    => HTMLInputElement,
    "button"   => HTMLButtonElement,
    "img"      => HTMLImageElement,
    "script"   => HTMLScriptElement,
    "link"     => HTMLLinkElement,
    "select"   => HTMLSelectElement,
    "option"   => HTMLOptionElement,
    "optgroup" => HTMLOptGroupElement,
    "textarea" => HTMLTextAreaElement,
    "label"    => HTMLLabelElement,
    "fieldset" => HTMLFieldsetElement,
    "output"   => HTMLOutputElement,
    "legend"   => HTMLLegendElement,
    "slot"     => HTMLSlotElement,
    "table"    => HTMLTableElement,
    "thead"    => HTMLTableSectionElement,
    "tbody"    => HTMLTableSectionElement,
    "tfoot"    => HTMLTableSectionElement,
    "tr"       => HTMLTableRowElement,
    "td"       => HTMLTableCellElement,
    "th"       => HTMLTableCellElement,
    "caption"  => HTMLTableCaptionElement,
    "dialog"   => HTMLDialogElement,
    "details"  => HTMLDetailsElement,
    "meter"    => HTMLMeterElement,
    "progress" => HTMLProgressElement,
    "template" => HTMLTemplateElement,
  }.freeze

  def self.element_class_for(tag_name)
    HTML_ELEMENT_CLASSES[tag_name.to_s.downcase] || Element
  end
end
