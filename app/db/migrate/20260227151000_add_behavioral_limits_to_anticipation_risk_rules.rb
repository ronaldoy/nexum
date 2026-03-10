class AddBehavioralLimitsToAnticipationRiskRules < ActiveRecord::Migration[8.2]
  def up
    add_column :anticipation_risk_rules, :max_requests_per_minute, :integer
    add_column :anticipation_risk_rules, :max_requests_per_hour, :integer
    add_column :anticipation_risk_rules, :pair_spike_multiplier, :decimal, precision: 12, scale: 4
    add_column :anticipation_risk_rules, :pair_spike_min_daily_amount, :decimal, precision: 18, scale: 2
    add_column :anticipation_risk_rules, :near_limit_attempts_window_minutes, :integer
    add_column :anticipation_risk_rules, :near_limit_attempts_max_count, :integer
    add_column :anticipation_risk_rules, :near_limit_ratio, :decimal, precision: 8, scale: 6

    add_check_constraint(
      :anticipation_risk_rules,
      "max_requests_per_minute IS NULL OR max_requests_per_minute > 0",
      name: "anticipation_risk_rules_requests_per_minute_positive_check"
    )
    add_check_constraint(
      :anticipation_risk_rules,
      "max_requests_per_hour IS NULL OR max_requests_per_hour > 0",
      name: "anticipation_risk_rules_requests_per_hour_positive_check"
    )
    add_check_constraint(
      :anticipation_risk_rules,
      "pair_spike_multiplier IS NULL OR pair_spike_multiplier > 1",
      name: "anticipation_risk_rules_pair_spike_multiplier_check"
    )
    add_check_constraint(
      :anticipation_risk_rules,
      "pair_spike_min_daily_amount IS NULL OR pair_spike_min_daily_amount > 0",
      name: "anticipation_risk_rules_pair_spike_min_daily_amount_check"
    )
    add_check_constraint(
      :anticipation_risk_rules,
      "near_limit_attempts_window_minutes IS NULL OR near_limit_attempts_window_minutes > 0",
      name: "anticipation_risk_rules_near_limit_window_positive_check"
    )
    add_check_constraint(
      :anticipation_risk_rules,
      "near_limit_attempts_max_count IS NULL OR near_limit_attempts_max_count > 0",
      name: "anticipation_risk_rules_near_limit_count_positive_check"
    )
    add_check_constraint(
      :anticipation_risk_rules,
      "near_limit_ratio IS NULL OR (near_limit_ratio > 0 AND near_limit_ratio <= 1)",
      name: "anticipation_risk_rules_near_limit_ratio_check"
    )
    add_check_constraint(
      :anticipation_risk_rules,
      "(near_limit_attempts_window_minutes IS NULL AND near_limit_attempts_max_count IS NULL) OR (near_limit_attempts_window_minutes IS NOT NULL AND near_limit_attempts_max_count IS NOT NULL)",
      name: "anticipation_risk_rules_near_limit_window_count_pair_check"
    )
    add_check_constraint(
      :anticipation_risk_rules,
      "(pair_spike_multiplier IS NULL AND pair_spike_min_daily_amount IS NULL) OR (pair_spike_multiplier IS NOT NULL AND pair_spike_min_daily_amount IS NOT NULL)",
      name: "anticipation_risk_rules_pair_spike_pair_check"
    )

    remove_check_constraint :anticipation_risk_rules, name: "anticipation_risk_rules_requires_any_limit_check"
    add_check_constraint(
      :anticipation_risk_rules,
      <<~SQL.squish,
        max_single_request_amount IS NOT NULL
        OR max_daily_requested_amount IS NOT NULL
        OR max_outstanding_exposure_amount IS NOT NULL
        OR max_open_requests_count IS NOT NULL
        OR max_requests_per_minute IS NOT NULL
        OR max_requests_per_hour IS NOT NULL
        OR pair_spike_multiplier IS NOT NULL
        OR near_limit_attempts_window_minutes IS NOT NULL
      SQL
      name: "anticipation_risk_rules_requires_any_limit_check"
    )
  end

  def down
    remove_check_constraint :anticipation_risk_rules, name: "anticipation_risk_rules_requires_any_limit_check"
    add_check_constraint(
      :anticipation_risk_rules,
      "max_single_request_amount IS NOT NULL OR max_daily_requested_amount IS NOT NULL OR max_outstanding_exposure_amount IS NOT NULL OR max_open_requests_count IS NOT NULL",
      name: "anticipation_risk_rules_requires_any_limit_check"
    )

    remove_check_constraint :anticipation_risk_rules, name: "anticipation_risk_rules_pair_spike_pair_check"
    remove_check_constraint :anticipation_risk_rules, name: "anticipation_risk_rules_near_limit_window_count_pair_check"
    remove_check_constraint :anticipation_risk_rules, name: "anticipation_risk_rules_near_limit_ratio_check"
    remove_check_constraint :anticipation_risk_rules, name: "anticipation_risk_rules_near_limit_count_positive_check"
    remove_check_constraint :anticipation_risk_rules, name: "anticipation_risk_rules_near_limit_window_positive_check"
    remove_check_constraint :anticipation_risk_rules, name: "anticipation_risk_rules_pair_spike_min_daily_amount_check"
    remove_check_constraint :anticipation_risk_rules, name: "anticipation_risk_rules_pair_spike_multiplier_check"
    remove_check_constraint :anticipation_risk_rules, name: "anticipation_risk_rules_requests_per_hour_positive_check"
    remove_check_constraint :anticipation_risk_rules, name: "anticipation_risk_rules_requests_per_minute_positive_check"

    remove_column :anticipation_risk_rules, :near_limit_ratio
    remove_column :anticipation_risk_rules, :near_limit_attempts_max_count
    remove_column :anticipation_risk_rules, :near_limit_attempts_window_minutes
    remove_column :anticipation_risk_rules, :pair_spike_min_daily_amount
    remove_column :anticipation_risk_rules, :pair_spike_multiplier
    remove_column :anticipation_risk_rules, :max_requests_per_hour
    remove_column :anticipation_risk_rules, :max_requests_per_minute
  end
end
