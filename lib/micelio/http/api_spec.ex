defmodule Micelio.HTTP.ApiSpec do
  @moduledoc false

  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{Components, Info, OpenApi, Operation, PathItem, Schema, SecurityScheme}

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Micelio API",
        version: Micelio.version(),
        description:
          "Repository issues and durable work runs. Issues live in private Git history; work-run coordination lives in the object store."
      },
      paths: paths(),
      components: %Components{
        securitySchemes: %{
          "bearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            description: "A credential accepted by Micelio's configured authentication backend."
          }
        },
        schemas: %{
          "Issue" => issue_schema(),
          "Comment" => comment_schema(),
          "WorkRun" => work_run_schema(),
          "WorkAttempt" => work_attempt_schema(),
          "WorkEvents" => work_events_schema(),
          "Error" => error_schema()
        }
      }
    }
  end

  defp paths do
    %{
      "/api/issues" => %PathItem{
        get: operation("listIssues", "List issues", [repository_parameter()], list_schema()),
        post:
          operation("createIssue", "Create issue", [repository_parameter()], mutation_schema(),
            request_body: create_issue_schema(),
            created?: true
          )
      },
      "/api/issues/{issue}" => %PathItem{
        get: operation("getIssue", "Get issue", issue_parameters(), issue_response_schema()),
        patch:
          operation("updateIssue", "Update issue", issue_parameters(), mutation_schema(),
            request_body: update_issue_schema()
          ),
        delete: operation("deleteIssue", "Delete issue", issue_parameters(), mutation_schema())
      },
      "/api/issues/{issue}/comments" => %PathItem{
        get: operation("listIssueComments", "List issue comments", issue_parameters(), comments_schema()),
        post:
          operation("createIssueComment", "Create issue comment", issue_parameters(), mutation_schema(),
            request_body: comment_body_schema(),
            created?: true
          )
      },
      "/api/issues/{issue}/comments/{comment}" => %PathItem{
        get:
          operation("getIssueComment", "Get issue comment", comment_parameters(), comment_response_schema()),
        patch:
          operation("updateIssueComment", "Update issue comment", comment_parameters(), mutation_schema(),
            request_body: comment_body_schema()
          ),
        delete:
          operation("deleteIssueComment", "Delete issue comment", comment_parameters(), mutation_schema())
      },
      "/api/issues/{issue}/history" => %PathItem{
        get: operation("getIssueHistory", "Get immutable issue history", issue_parameters(), history_schema())
      },
      "/api/work-runs" => %PathItem{
        get:
          operation("listWorkRuns", "List work runs", [repository_parameter()], work_run_list_schema(),
            tags: ["Work runs"]
          ),
        post:
          operation("createWorkRun", "Create work run", [repository_parameter()], work_run_schema(),
            request_body: create_work_run_schema(),
            created?: true,
            tags: ["Work runs"]
          )
      },
      "/api/work-runs/{run}" => %PathItem{
        get:
          operation("getWorkRun", "Get work run", work_run_parameters(), work_run_schema(),
            tags: ["Work runs"]
          )
      },
      "/api/work-runs/{run}/events" => %PathItem{
        get:
          operation(
            "getWorkRunEvents",
            "Get immutable work-run events",
            work_run_parameters() ++
              [Operation.parameter(:after, :query, :integer, "Exclusive state-revision cursor")],
            work_events_schema(),
            tags: ["Work runs"]
          )
      },
      "/api/work-runs/{run}/attempts/{attempt}" => %PathItem{
        get:
          operation(
            "getWorkAttempt",
            "Get work attempt evidence",
            work_run_parameters() ++ [Operation.parameter(:attempt, :path, :string, "Attempt identifier")],
            work_attempt_schema(),
            tags: ["Work runs"]
          )
      },
      "/api/work-runs/{run}/claim" => %PathItem{
        post:
          operation("claimWorkNode", "Claim a ready work node", work_run_parameters(), work_run_schema(),
            request_body: claim_work_node_schema(),
            tags: ["Work runs"]
          )
      },
      "/api/work-runs/{run}/nodes/{node}/complete" => %PathItem{
        post:
          operation(
            "completeWorkAttempt",
            "Complete a claimed work node",
            work_node_parameters(),
            work_run_schema(),
            request_body: complete_work_attempt_schema(),
            tags: ["Work runs"]
          )
      },
      "/api/work-runs/{run}/nodes/{node}/approve" => %PathItem{
        post:
          operation("approveWorkNode", "Approve a waiting node", work_node_parameters(), work_run_schema(),
            tags: ["Work runs"]
          )
      },
      "/api/work-runs/{run}/nodes/{node}/expire" => %PathItem{
        post:
          operation("expireWorkNode", "Requeue a stale work node", work_node_parameters(), work_run_schema(),
            tags: ["Work runs"]
          )
      },
      "/api/work-runs/{run}/cancel" => %PathItem{
        post:
          operation("cancelWorkRun", "Cancel a work run", work_run_parameters(), work_run_schema(),
            tags: ["Work runs"]
          )
      }
    }
  end

  defp operation(id, summary, parameters, schema, opts \\ []) do
    responses =
      %{
        if(opts[:created?], do: "201", else: "200") =>
          Operation.response("Success", "application/json", schema),
        "401" => Operation.response("Authentication required", "application/json", error_schema()),
        "403" => Operation.response("Permission denied", "application/json", error_schema()),
        "404" => Operation.response("Repository or issue not found", "application/json", error_schema()),
        "409" => Operation.response("Concurrent update", "application/json", error_schema()),
        "422" => Operation.response("Invalid request", "application/json", error_schema())
      }

    %Operation{
      tags: opts[:tags] || ["Issues"],
      operationId: id,
      summary: summary,
      parameters: parameters,
      requestBody:
        if(opts[:request_body],
          do: Operation.request_body("Request body", "application/json", opts[:request_body], required: true)
        ),
      responses: responses,
      security: [%{"bearerAuth" => []}]
    }
  end

  defp repository_parameter do
    Operation.parameter(:repository, :query, :string, "Repository identifier, for example acme/app.",
      required: true
    )
  end

  defp issue_parameters do
    [Operation.parameter(:issue, :path, :integer, "Positive issue number"), repository_parameter()]
  end

  defp comment_parameters do
    issue_parameters() ++ [Operation.parameter(:comment, :path, :string, "Comment identifier")]
  end

  defp work_run_parameters do
    [Operation.parameter(:run, :path, :string, "Work-run identifier"), repository_parameter()]
  end

  defp work_node_parameters do
    work_run_parameters() ++ [Operation.parameter(:node, :path, :string, "Work-node identifier")]
  end

  defp author_schema do
    %Schema{
      type: :object,
      required: [:subject],
      properties: %{subject: %Schema{type: :string}, account: %Schema{type: :string}}
    }
  end

  defp comment_schema do
    %Schema{
      type: :object,
      required: [:id, :author, :created_at],
      properties: %{
        id: %Schema{type: :string},
        author: author_schema(),
        body: %Schema{type: :string},
        created_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"},
        deleted: %Schema{type: :boolean},
        deleted_at: %Schema{type: :string, format: :"date-time"}
      }
    }
  end

  defp issue_schema do
    %Schema{
      type: :object,
      required: [:number, :title, :body, :state, :author, :created_at, :updated_at, :comments, :comment_count],
      properties: %{
        number: %Schema{type: :integer, minimum: 1},
        title: %Schema{type: :string},
        body: %Schema{type: :string},
        state: %Schema{type: :string, enum: ["open", "closed", "deleted"]},
        author: author_schema(),
        created_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"},
        comments: %Schema{type: :array, items: comment_schema()},
        comment_count: %Schema{type: :integer, minimum: 0}
      }
    }
  end

  defp create_issue_schema do
    %Schema{
      type: :object,
      required: [:title],
      properties: %{title: %Schema{type: :string, minLength: 1}, body: %Schema{type: :string}}
    }
  end

  defp update_issue_schema do
    %Schema{
      type: :object,
      properties: %{
        title: %Schema{type: :string, minLength: 1},
        body: %Schema{type: :string},
        state: %Schema{type: :string, enum: ["open", "closed"]}
      }
    }
  end

  defp comment_body_schema do
    %Schema{type: :object, required: [:body], properties: %{body: %Schema{type: :string, minLength: 1}}}
  end

  defp issue_response_schema do
    %Schema{type: :object, required: [:issue], properties: %{issue: issue_schema()}}
  end

  defp list_schema do
    %Schema{
      type: :object,
      required: [:issues, :count],
      properties: %{
        issues: %Schema{type: :array, items: issue_schema()},
        count: %Schema{type: :integer, minimum: 0}
      }
    }
  end

  defp comments_schema do
    %Schema{
      type: :object,
      required: [:issue, :comments, :count],
      properties: %{
        issue: %Schema{type: :integer, minimum: 1},
        comments: %Schema{type: :array, items: comment_schema()},
        count: %Schema{type: :integer, minimum: 0}
      }
    }
  end

  defp comment_response_schema do
    %Schema{
      type: :object,
      required: [:issue, :comment],
      properties: %{issue: %Schema{type: :integer, minimum: 1}, comment: comment_schema()}
    }
  end

  defp mutation_schema do
    %Schema{
      type: :object,
      required: [:issue, :seq, :epoch],
      properties: %{
        issue: issue_schema(),
        seq: %Schema{type: :integer, minimum: 1},
        epoch: %Schema{type: :integer, minimum: 0}
      }
    }
  end

  defp history_schema do
    %Schema{
      type: :object,
      required: [:issue, :events, :count],
      properties: %{
        issue: %Schema{type: :integer, minimum: 1},
        events: %Schema{type: :array, items: %Schema{type: :object}},
        count: %Schema{type: :integer, minimum: 1}
      }
    }
  end

  defp create_work_run_schema do
    %Schema{
      type: :object,
      required: [:graph, :base_commit],
      properties: %{
        graph: graph_schema(),
        base_commit: %Schema{type: :string, pattern: "^[0-9a-f]{40}$"},
        issue: %Schema{type: :integer, minimum: 1},
        lease_duration_ms: %Schema{type: :integer, minimum: 1_000, maximum: 86_400_000}
      }
    }
  end

  defp graph_schema do
    %Schema{
      type: :object,
      required: [:nodes],
      properties: %{
        nodes: %Schema{type: :array, minItems: 1, items: work_node_schema()}
      }
    }
  end

  defp work_node_schema do
    %Schema{
      type: :object,
      required: [:id, :title],
      properties: %{
        id: %Schema{type: :string},
        kind: %Schema{type: :string, enum: ["agent", "command", "evaluate", "approval"]},
        title: %Schema{type: :string},
        depends_on: %Schema{type: :array, items: %Schema{type: :string}},
        status: %Schema{
          type: :string,
          enum: ["pending", "ready", "waiting", "running", "succeeded", "failed", "skipped"]
        },
        attempts: %Schema{type: :integer, minimum: 0},
        attempt_id: %Schema{type: :string},
        result_attempt: %Schema{type: :string},
        rejected_result_attempt_ids: %Schema{type: :array, items: %Schema{type: :string}},
        expired_attempt_ids: %Schema{type: :array, items: %Schema{type: :string}},
        claimed_by: author_schema(),
        execution: execution_schema()
      }
    }
  end

  defp execution_schema do
    %Schema{
      type: :object,
      properties: %{
        type: %Schema{type: :string, enum: ["condukt_operation"]},
        operation: %Schema{type: :string},
        input: %Schema{type: :object},
        output_schema: %Schema{type: :object}
      }
    }
  end

  defp work_run_schema do
    %Schema{
      type: :object,
      required: [:id, :repository, :base_commit, :graph, :status, :revision, :nodes],
      properties: %{
        id: %Schema{type: :string},
        run_id: %Schema{type: :string},
        repository: %Schema{type: :string},
        issue: %Schema{type: :integer, minimum: 1},
        base_commit: %Schema{type: :string},
        graph: graph_schema(),
        lease_duration_ms: %Schema{type: :integer},
        created_at_ms: %Schema{type: :integer},
        created_by: author_schema(),
        status: %Schema{type: :string, enum: ["active", "succeeded", "failed", "cancelled"]},
        revision: %Schema{type: :integer, minimum: 1},
        nodes: %Schema{type: :array, items: work_node_schema()},
        attempt: %Schema{type: :object},
        attempt_id: %Schema{type: :string},
        accepted: %Schema{type: :boolean},
        work: %Schema{type: :object}
      }
    }
  end

  defp work_run_list_schema do
    %Schema{
      type: :object,
      required: [:repository, :runs, :count],
      properties: %{
        repository: %Schema{type: :string},
        runs: %Schema{type: :array, items: work_run_schema()},
        count: %Schema{type: :integer, minimum: 0}
      }
    }
  end

  defp claim_work_node_schema do
    %Schema{
      type: :object,
      required: [:executor],
      properties: %{executor: %Schema{type: :string, minLength: 1}}
    }
  end

  defp complete_work_attempt_schema do
    %Schema{
      type: :object,
      required: [:attempt, :outcome],
      properties: %{
        attempt: %Schema{type: :string},
        outcome: %Schema{type: :string, enum: ["succeeded", "failed"]},
        artifacts: %Schema{type: :array, items: %Schema{type: :object, required: [:name]}}
      }
    }
  end

  defp work_attempt_schema do
    %Schema{
      type: :object,
      required: [:attempt],
      properties: %{attempt: %Schema{type: :object}, result: %Schema{type: :object}}
    }
  end

  defp work_events_schema do
    %Schema{
      type: :object,
      required: [:run_id, :events, :count, :next_cursor],
      properties: %{
        run_id: %Schema{type: :string},
        events: %Schema{type: :array, items: %Schema{type: :object}},
        count: %Schema{type: :integer, minimum: 0},
        next_cursor: %Schema{type: :integer, minimum: 1}
      }
    }
  end

  defp error_schema do
    %Schema{type: :object, required: [:error], properties: %{error: %Schema{type: :string}}}
  end
end
