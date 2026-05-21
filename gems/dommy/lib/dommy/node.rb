# frozen_string_literal: true

module Dommy
  # `NodeList` — Array sub-class that adds the DOM NodeList surface
  # (`item(i)` / `forEach(cb)` / `entries` / `keys` / `values`) on
  # top of regular Array operations. Returned from
  # `querySelectorAll`, `getElementsBy*`, `childNodes`, etc.
  #
  # Live vs. static collections aren't distinguished here — Dommy
  # snapshots tree state at the time of the query, matching what
  # most happy-dom test patterns expect.
  class NodeList < Array
    def item(index)
      i = index.to_i
      return nil if i < 0 || i >= length

      self[i]
    end

    # Spec signature: `forEach(callback(value, key, listObj))`. The
    # Ruby `each_with_index` block-arg order is (value, index), which
    # we re-yield as (value, index, self) for spec parity.
    def for_each(&block)
      each_with_index do |value, index|
        block.call(value, index, self)
      end
      nil
    end
    alias forEach for_each

    # NodeList `entries` returns an enumerator of [index, value].
    def entries
      each_with_index.map { |value, index| [index, value] }
    end

    def keys
      (0...length).to_a
    end

    # `values` is the iterator of the NodeList itself; we return
    # `self.to_a` (a plain Array copy) so callers can't mutate
    # the original list.
    def values
      to_a
    end
  end

  # `Node` — common base mixin. All node-like classes (Element,
  # TextNode, CommentNode, CharacterDataNode, Document, Fragment,
  # DocumentType, ShadowRoot) include this so `el.is_a?(Dommy::Node)`
  # works.
  #
  # Real classes already define `nodeType` / `nodeName` / `nodeValue`
  # / `parentNode` / `isConnected` / `cloneNode` independently; this
  # module is primarily an identity marker. Adding new shared methods
  # later is straightforward.
  module Node
    # Standardized nodeType constants — duplicated from Element so
    # callers can refer to `Dommy::Node::ELEMENT_NODE` without
    # depending on a specific subclass.
    ELEMENT_NODE                = 1
    ATTRIBUTE_NODE              = 2
    TEXT_NODE                   = 3
    CDATA_SECTION_NODE          = 4
    PROCESSING_INSTRUCTION_NODE = 7
    COMMENT_NODE                = 8
    DOCUMENT_NODE               = 9
    DOCUMENT_TYPE_NODE          = 10
    DOCUMENT_FRAGMENT_NODE      = 11

    DOCUMENT_POSITION_DISCONNECTED            = 0x01
    DOCUMENT_POSITION_PRECEDING               = 0x02
    DOCUMENT_POSITION_FOLLOWING               = 0x04
    DOCUMENT_POSITION_CONTAINS                = 0x08
    DOCUMENT_POSITION_CONTAINED_BY            = 0x10
    DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC = 0x20
  end
end
