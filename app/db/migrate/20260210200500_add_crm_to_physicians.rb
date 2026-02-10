class AddCrmToPhysicians < ActiveRecord::Migration[8.2]
  BRAZILIAN_STATES = %w[
    AC AL AP AM BA CE DF ES GO MA MT MS MG PA PB PR PE PI RJ RN RS RO RR SC SP SE TO
  ].freeze

  def up
    add_column :physicians, :crm_number, :string
    add_column :physicians, :crm_state, :string, limit: 2

    execute <<~SQL
      UPDATE physicians
      SET
        crm_number = NULLIF(regexp_replace(professional_registry::text, '[^0-9]+', '', 'g'), ''),
        crm_state = UPPER((regexp_match(professional_registry::text, '(?i)\\m(AC|AL|AP|AM|BA|CE|DF|ES|GO|MA|MT|MS|MG|PA|PB|PR|PE|PI|RJ|RN|RS|RO|RR|SC|SP|SE|TO)\\M'))[1])
      WHERE professional_registry IS NOT NULL;
    SQL

    remove_index :physicians, name: "index_physicians_on_tenant_id_and_professional_registry"
    remove_column :physicians, :professional_registry, :string

    add_check_constraint :physicians,
      "(crm_number IS NULL AND crm_state IS NULL) OR (crm_number IS NOT NULL AND crm_state IS NOT NULL)",
      name: "physicians_crm_pair_presence_check"
    add_check_constraint :physicians,
      "crm_state IS NULL OR crm_state IN ('#{BRAZILIAN_STATES.join("','")}')",
      name: "physicians_crm_state_check"
    add_check_constraint :physicians,
      "crm_number IS NULL OR char_length(crm_number) BETWEEN 4 AND 10",
      name: "physicians_crm_number_length_check"

    add_index :physicians,
      %i[tenant_id crm_state crm_number],
      unique: true,
      where: "crm_number IS NOT NULL",
      name: "idx_physicians_tenant_crm"
  end

  def down
    remove_index :physicians, name: "idx_physicians_tenant_crm"
    remove_check_constraint :physicians, name: "physicians_crm_number_length_check"
    remove_check_constraint :physicians, name: "physicians_crm_state_check"
    remove_check_constraint :physicians, name: "physicians_crm_pair_presence_check"

    add_column :physicians, :professional_registry, :string
    execute <<~SQL
      UPDATE physicians
      SET professional_registry = CASE
        WHEN crm_number IS NULL THEN NULL
        WHEN crm_state IS NULL THEN crm_number
        ELSE crm_number || '-' || crm_state
      END;
    SQL
    add_index :physicians, %i[tenant_id professional_registry], unique: true, where: "professional_registry IS NOT NULL", name: "index_physicians_on_tenant_id_and_professional_registry"

    remove_column :physicians, :crm_state, :string
    remove_column :physicians, :crm_number, :string
  end
end
