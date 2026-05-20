# frozen_string_literal: true

require_relative "test_helper"
require "json"

class TestLiveReload < Minitest::Test
  def test_subscriber_count_starts_at_zero
    lr = Lilac::CLI::LiveReload.new
    assert_equal 0, lr.subscriber_count
  end

  def test_notify_all_pushes_to_each_subscriber_queue
    lr = Lilac::CLI::LiveReload.new

    queues = Array.new(3) { Queue.new }
    queues.each { |q| lr.instance_variable_get(:@subscribers) << q }

    lr.notify_all("reload")

    queues.each do |q|
      assert_equal "reload", q.pop(timeout: 0.1)
    end
  end

  def test_notify_all_with_no_subscribers_is_a_noop
    lr = Lilac::CLI::LiveReload.new
    lr.notify_all  # must not raise
  end

  def test_endpoint_path_is_namespaced
    # Documents the public contract — the script Builder injects is
    # hard-coded to this path; keep them in sync.
    assert_equal "/__lilac/livereload", Lilac::CLI::LiveReload::ENDPOINT_PATH
  end

  def test_notify_error_pushes_tagged_payload_to_subscribers
    lr = Lilac::CLI::LiveReload.new
    queue = Queue.new
    lr.instance_variable_get(:@subscribers) << queue

    lr.notify_error(type: "Builder::Error", message: "boom\nnext line")

    msg = queue.pop(timeout: 0.1)
    assert_kind_of Array, msg
    assert_equal Lilac::CLI::LiveReload::ERROR_MARKER, msg.first
    # Payload is JSON-encoded so the SSE line stays single-line on the
    # wire even when message contains newlines.
    payload = JSON.parse(msg.last)
    assert_equal "Builder::Error", payload["type"]
    assert_equal "boom\nnext line", payload["message"]
  end

  def test_format_frame_distinguishes_reload_and_error
    lr = Lilac::CLI::LiveReload.new
    reload_frame = lr.send(:format_frame, "reload")
    assert_equal "data: reload\n\n", reload_frame

    error_frame = lr.send(:format_frame, [Lilac::CLI::LiveReload::ERROR_MARKER, '{"foo":1}'])
    assert_equal "event: error\ndata: {\"foo\":1}\n\n", error_frame

    keepalive = lr.send(:format_frame, nil)
    assert_equal ":keepalive\n\n", keepalive
  end
end
