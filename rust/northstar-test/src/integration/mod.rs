pub mod analytics_query;
pub mod caching_replication;
pub mod disaster_recovery;
pub mod end_to_end;
pub mod stress_tests;
pub mod common;

// Cloud integration tests
#[cfg(feature = "cloud-tests")]
pub mod cloud_common;
#[cfg(feature = "cloud-tests")]
pub mod cloud_aws;
// TODO: Add cloud_gcs and cloud_azure when implemented
// #[cfg(feature = "cloud-tests")]
// pub mod cloud_gcs;
// #[cfg(feature = "cloud-tests")]
// pub mod cloud_azure;
