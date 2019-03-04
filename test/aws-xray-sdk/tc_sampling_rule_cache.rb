require_relative '../test_helper'
require 'aws-xray-sdk/sampling/rule_cache'
require 'aws-xray-sdk/sampling/sampling_rule'

# Test sampling rule cache
class TestSamplingRuleCache < Minitest::Test
  RuleDef = Struct.new(:rule_name, :priority, :fixed_rate,
                       :host, :http_method, :url_path,
                       :service_name, :service_type, :reservoir_size)
  SamplingTarget = Struct.new(:fixed_rate, :reservoir_quota,
                              :reservoir_quota_ttl, :interval)

  def setup
    @@rule0 = XRay::SamplingRule.new RuleDef.new('asd', 0, 0.1, '*', '*', '*', 'anotherService', '*', 1)
    @@rule1 = XRay::SamplingRule.new RuleDef.new('a', 1, 0.1, '*mydomain*', 'GET',
                                                 'myop', 'random_name', '*', 1)
    @@rule2 = XRay::SamplingRule.new RuleDef.new('aa', 2, 0.1, '*random*', 'POST',
                                                 'random', 'proxy', '*', 1)
    @@rule3 = XRay::SamplingRule.new RuleDef.new('b', 3, 0.1, '*', '*', '*',
                                                 '*', 'AWS::EC2::Instance', 1)
    @@rule_default = XRay::SamplingRule.new RuleDef.new('Default', 10000, 0.1, '*',
                                                        '*', '*', '*', '*', 1)
  end

  def test_rules_sorting
   cache = XRay::RuleCache.new
   cache.load_rules [@@rule_default, @@rule2, @@rule0, @@rule1, @@rule3]
   sorted_rules = cache.rules

   assert_equal 'asd', sorted_rules[0].name
   assert_equal 'a', sorted_rules[1].name
   assert_equal 'aa', sorted_rules[2].name
   assert_equal 'b', sorted_rules[3].name
   assert_equal 'Default', sorted_rules[4].name
  end

  def test_evict_deleted_rules
   cache = XRay::RuleCache.new
   cache.load_rules [@@rule_default, @@rule0, @@rule1]
   cache.load_rules [@@rule_default, @@rule2]

   rules = cache.rules
   assert_equal 2, rules.length
   assert rules.include?(@@rule_default)
   assert rules.include?(@@rule2)
  end

  def test_preserving_sampling_statistics
   now = Time.now.to_i
   cache = XRay::RuleCache.new
   cache.load_rules [@@rule_default, @@rule1]
   @@rule1.increment_request_count
   @@rule1.increment_sampled_count
   @@rule1.reservoir.load_target_info quota: 3, ttl: now, interval: nil
   updated_rule0 = XRay::SamplingRule.new RuleDef.new('a', 1, 0.1, '*', 'GET',
                                                      'myop', '*', '*', 1)
   cache.load_rules [@@rule_default, updated_rule0]
   new_rule0 = cache.rules[0]

   assert_equal 1, new_rule0.request_count
   assert_equal 1, new_rule0.sampled_count
   assert_equal 3, new_rule0.reservoir.quota
   assert_equal now, new_rule0.reservoir.ttl
  end

  def test_target_mapping
   cache = XRay::RuleCache.new
   cache.load_rules [@@rule_default, @@rule1]
   targets = {
     'a' => SamplingTarget.new(0.1, 5, nil, nil),
     'b'=> SamplingTarget.new(0.1, 6, nil, nil),
     'Default' => SamplingTarget.new(0.1, 7, nil, nil),
   }
   cache.load_targets(targets)

   assert_equal 5, cache.rules[0].reservoir.quota
   assert_equal 7, cache.rules[1].reservoir.quota
  end

  def test_expired_cache
   now = Time.now.to_i
   cache = XRay::RuleCache.new
   cache.load_rules [@@rule_default, @@rule2, @@rule0, @@rule1, @@rule3]
   cache.last_updated = now - 60 * 60 * 3 # 2 hours passed cache TTL

   assert_nil cache.get_matched_rule({host: 'nomatch'}, now: now)

   cache.last_updated = now
   assert cache.get_matched_rule({http_method: 'nil', host: 'nil'}, now: now).default?
  end

  def test_rule_matching
    now = Time.now.to_i
    cache = XRay::RuleCache.new
    cache.load_rules [@@rule_default, @@rule1, @@rule2, @@rule3, @@rule0]
    cache.last_updated = now

    sampling_req = {host: 'mydomain.com', http_method: 'GET', url_path: 'myop', service: 'random_name'}
    rule = cache.get_matched_rule(sampling_req, now: now)
    assert_equal 'a', rule.name

    sampling_req = {http_method: 'POST', url_path: 'random', service: 'proxy', host: 'random.com'}
    rule = cache.get_matched_rule(sampling_req, now: now)
    assert_equal 'aa', rule.name

    sampling_req = {service_type: 'AWS::EC2::Instance'}
    rule = cache.get_matched_rule(sampling_req, now: now)
    assert_equal 'b', rule.name

    # Default should be always returned when there is no match
    sampling_req = {host: 'unknown', url_path: 'unknown'}
    rule = cache.get_matched_rule(sampling_req, now: now)
    assert rule.default?

    #should evaluate to default if there is no input
    sampling_req = {}
    rule = cache.get_matched_rule(sampling_req, now: now)
    assert rule.default?

    sampling_req = {service: 'anotherService'}
    rule = cache.get_matched_rule(sampling_req, now: now)
    assert_equal 'asd', rule.name
  end
end
