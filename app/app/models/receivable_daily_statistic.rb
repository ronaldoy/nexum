class ReceivableDailyStatistic < ApplicationRecord
  self.table_name = "receivable_statistics_daily"

  METRIC_SCOPES = %w[GLOBAL DEBTOR CREDITOR BENEFICIARY].freeze

  belongs_to :tenant
  belongs_to :receivable_kind
  belongs_to :scope_party, class_name: "Party", optional: true

  validates :stat_date, presence: true
  validates :metric_scope, presence: true, inclusion: { in: METRIC_SCOPES }
end
