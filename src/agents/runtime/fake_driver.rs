//! FakeModelDriver for deterministic testing without external APIs.

use crate::agents::runtime::event::{ModelEvent, ModelStopReason, ToolCallData};
use crate::agents::runtime::model::{
    ModelCapabilities, ModelDriver, ModelEventStream, ModelRequest,
};
use std::pin::Pin;

#[derive(Debug, Clone)]
pub enum FakeStep {
    Text(String),
    ToolCall {
        name: String,
        args: serde_json::Value,
    },
    Error(String),
    StopEndTurn,
}

pub struct FakeModelDriver {
    pub steps: Vec<FakeStep>,
}

impl FakeModelDriver {
    pub fn text_only(reply: &str) -> Self {
        Self {
            steps: vec![FakeStep::Text(reply.to_string()), FakeStep::StopEndTurn],
        }
    }

    pub fn error(message: &str) -> Self {
        Self {
            steps: vec![FakeStep::Error(message.to_string())],
        }
    }
}

impl ModelDriver for FakeModelDriver {
    fn provider(&self) -> &str {
        "fake"
    }

    fn model(&self) -> &str {
        "fake-model"
    }

    fn capabilities(&self) -> ModelCapabilities {
        ModelCapabilities::default()
    }

    fn stream_step<'life0, 'async_trait>(
        &'life0 self,
        _request: ModelRequest,
    ) -> Pin<Box<dyn Future<Output = anyhow::Result<ModelEventStream>> + Send + 'async_trait>>
    where
        'life0: 'async_trait,
        Self: 'async_trait,
    {
        let steps = self.steps.clone();
        Box::pin(async move {
            let stream = async_stream::stream! {
                for step in &steps {
                    match step {
                        FakeStep::Text(text) => {
                            yield Ok(ModelEvent::TextDelta(text.clone()));
                        }
                        FakeStep::ToolCall { name, args } => {
                            yield Ok(ModelEvent::ToolCall(ToolCallData {
                                id: format!("tool_{}", name),
                                call_id: Some(format!("call_{}", name)),
                                name: name.clone(),
                                arguments: args.clone(),
                            }));
                        }
                        FakeStep::Error(msg) => {
                            yield Err(anyhow::anyhow!("{}", msg));
                        }
                        FakeStep::StopEndTurn => {
                            yield Ok(ModelEvent::Stop(ModelStopReason::EndTurn));
                        }
                    }
                }
            };
            Ok(Box::pin(stream) as ModelEventStream)
        })
    }
}

use std::future::Future;
