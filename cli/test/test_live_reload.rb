# frozen_string_literal: true

require_relative "test_helper"

class TestLiveReload < Minitest::Test
  def test_subscriber_count_starts_at_zero
    lr = Grainet::CLI::LiveReload.new
    assert_equal 0, lr.subscriber_count
  end

  def test_notify_all_pushes_to_each_subscriber_queue
    lr = Grainet::CLI::LiveReload.new

    queues = Array.new(3) { Queue.new }
    queues.each { |q| lr.instance_variable_get(:@subscribers) << q }

    lr.notify_all("reload")

    queues.each do |q|
      assert_equal "reload", q.pop(timeout: 0.1)
    end
  end

  def test_notify_all_with_no_subscribers_is_a_noop
    lr = Grainet::CLI::LiveReload.new
    lr.notify_all  # must not raise
  end

  def test_endpoint_path_is_namespaced
    # Documents the public contract — the script Builder injects is
    # hard-coded to this path; keep them in sync.
    assert_equal "/__grainet/livereload", Grainet::CLI::LiveReload::ENDPOINT_PATH
  end
end
