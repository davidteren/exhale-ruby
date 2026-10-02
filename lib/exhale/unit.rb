# frozen_string_literal: true

module Exhale
  # Anything that can appear in a finding: a method, the body of a Rails DSL
  # call, or an ERB template. Fragments are found inside units later; they
  # aren't units of their own.
  #
  # kind      - :method, :dsl or :template.
  # identity  - Survives a file move. "Billing::Invoice#total" for an instance
  #             method, "Billing::Invoice.build" for a singleton method,
  #             "Order.scope(:settled)" or "Order.before_save[2]" for a DSL
  #             body, "views/orders/_form.html.erb" for a template (its path
  #             under app/).
  # namespace - "Billing::Invoice" for a Ruby unit ("Object" at top level),
  #             nil for a template.
  # name      - "total", "build", "scope(:settled)"; nil for a template.
  # path      - Path relative to the repository root.
  # language  - :ruby or :erb.
  # node      - The parser node the unit covers (a Prism::Node, or a Herb
  #             node). Held in memory only; never cached.
  Unit = Struct.new(:kind, :identity, :namespace, :name, :path, :start_line, :end_line, :language, :node,
                    keyword_init: true) do
    def lines
      end_line - start_line + 1
    end
  end
end
