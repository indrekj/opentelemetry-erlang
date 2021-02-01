defmodule OtelTests do
  use ExUnit.Case, async: true

  require OpenTelemetry.Tracer, as: Tracer
  require OpenTelemetry.Span, as: Span
  require OpenTelemetry.Ctx, as: Ctx

  require Record
  @fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @fields)
  @fields Record.extract(:span_ctx, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
  Record.defrecordp(:span_ctx, @fields)

  test "use Tracer to set current active Span's attributes" do
    :otel_batch_processor.set_exporter(:otel_exporter_pid, self())
    OpenTelemetry.register_tracer(:test_tracer, "0.1.0")

    Tracer.with_span "span-1" do
      Tracer.set_attribute("attr-1", "value-1")
      Tracer.set_attributes([{"attr-2", "value-2"}])
    end

    assert_receive {:span,
                    span(
                      name: "span-1",
                      attributes: [{"attr-1", "value-1"}, {"attr-2", "value-2"}]
                    )}
  end

  test "use Tracer to start a Span as currently active with an explicit parent" do
    :otel_batch_processor.set_exporter(:otel_exporter_pid, self())
    OpenTelemetry.register_tracer(:test_tracer, "0.1.0")

    s1 = Tracer.start_span("span-1")
    ctx = Tracer.set_current_span(Ctx.new(), s1)

    Tracer.with_span ctx, "span-2", %{} do
      Tracer.set_attribute("attr-1", "value-1")
      Tracer.set_attributes([{"attr-2", "value-2"}])
    end

    span_ctx(span_id: parent_span_id) = Span.end_span(s1)

    assert_receive {:span,
                    span(
                      name: "span-1",
                      attributes: []
                    )}

    assert_receive {:span,
                    span(
                      name: "span-2",
                      parent_span_id: ^parent_span_id,
                      attributes: [{"attr-1", "value-1"}, {"attr-2", "value-2"}]
                    )}
  end

  test "use Span to set attributes" do
    :otel_batch_processor.set_exporter(:otel_exporter_pid, self())

    s = Tracer.start_span("span-2")
    Span.set_attribute(s, "attr-1", "value-1")
    Span.set_attributes(s, [{"attr-2", "value-2"}])

    assert span_ctx() = Span.end_span(s)

    assert_receive {:span,
                    span(
                      name: "span-2",
                      attributes: [{"attr-1", "value-1"}, {"attr-2", "value-2"}]
                    )}
  end

  test "create child Span in Task" do
    :otel_batch_processor.set_exporter(:otel_exporter_pid, self())
    OpenTelemetry.register_tracer(:test_tracer, "0.1.0")

    # create the parent span
    parent = Tracer.start_span("parent")
    # make a new context with it as the active span
    ctx = Tracer.set_current_span(Ctx.new(), parent)
    # attach this context (put it in the process dictionary)
    Ctx.attach(ctx)

    # start the child and set it to current in an unattached context
    child = Tracer.start_span("child")
    ctx = Tracer.set_current_span(ctx, SpanCtx)

    task = Task.async(
      fn ->
        # attach the context with the child span active to this process
        Ctx.attach(ctx)
        Span.end_span(child)
        :hello
      end)

    ret = Task.await(task)
    assert :hello = ret

    span_ctx(span_id: parent_span_id) = Span.end_span(parent)

    assert_receive {:span,
                    span(
                      name: "child",
                      parent_span_id: ^parent_span_id
                    )}
  end

  test "create Span with Link to outer Span in Task" do
    :otel_batch_processor.set_exporter(:otel_exporter_pid, self())
    OpenTelemetry.register_tracer(:test_tracer, "0.1.0")

    parent_ctx = Ctx.new()

    # create the parent span
    parent = Tracer.start_span("parent")
    # make a new context with it as the active span
    ctx = Tracer.set_current_span(parent_ctx, parent)
    # attach this context (put it in the process dictionary)
    Ctx.attach(ctx)

    task = Task.async(
      fn ->
        # new process has a new context so this span will have no parent
        parent_link = OpenTelemetry.link(parent)
        assert parent_link != :undefined
        Tracer.with_span "child", %{links: [parent_link]} do
          :hello
        end
      end)

    ret = Task.await(task)
    assert :hello = ret

    assert_receive {:span,
                    span(
                      name: "child",
                      parent_span_id: :undefined,
                      links: [_]
                    )}
  end

  test "use explicit Context for parent of started Span" do
    :otel_batch_processor.set_exporter(:otel_exporter_pid, self())

    s1 = Tracer.start_span("span-1")
    ctx = Tracer.set_current_span(Ctx.new(), s1)

    # span-2 will have s1 as the parent since s1 is the current span in `ctx`
    s2 = Tracer.start_span(ctx, "span-2", %{})

    # span-3 will have no parent because it uses the current context
    s3 = Tracer.start_span("span-3")

    Span.set_attribute(s1, "attr-1", "value-1")
    Span.set_attributes(s1, [{"attr-2", "value-2"}])

    span_ctx(span_id: s1_span_id) = Span.end_span(s1)

    assert span_ctx() = Span.end_span(s2)
    assert span_ctx() = Span.end_span(s3)

    assert_receive {:span,
                    span(
                      name: "span-1",
                      parent_span_id: :undefined,
                      attributes: [{"attr-1", "value-1"}, {"attr-2", "value-2"}]
                    )}

    assert_receive {:span,
                    span(
                      name: "span-2",
                      parent_span_id: ^s1_span_id
                    )}

    assert_receive {:span,
                    span(
                      name: "span-3",
                      parent_span_id: :undefined
                    )}
  end
end
