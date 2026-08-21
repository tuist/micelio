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
        description: "Repository issues and comments, persisted in the repository's private Git history."
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
      tags: ["Issues"],
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

  defp error_schema do
    %Schema{type: :object, required: [:error], properties: %{error: %Schema{type: :string}}}
  end
end
