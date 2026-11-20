# GovMove

Streamlit Databricks App that returns the nearest available government properties to a UK postcode, using
straight-line (Pythagorean) distance on British National Grid (EPSG:27700) Easting/Northing.

## Configuration values to replace before deployment

| Setting (env var in app.yaml) | Placeholder | Development default |
| --- | --- | --- |
| `GOVMOVE_CATALOG` | `<catalog_name>` | `manual_sandbox_dev` |
| `GOVMOVE_SCHEMA` | `<schema_name>` | `property_prioritisation` |
| `GOVMOVE_PROPERTY_TABLE` | `<property_table_name>` | `govmove_property_locations` |
| `GOVMOVE_POSTCODE_TABLE` | `<postcode_lookup_table_name>` | `govmove_postcode_centroids` |
| `GOVMOVE_POSTCODE_FALLBACK_TABLE` | `<catalog>.<schema>.<address_table>` | `address_dev.bronze.addressbasepremium` |
| `GOVMOVE_COMPUTE` | `serverless` or `<cluster_id>` | `serverless` |
| `GOVMOVE_SQL_WAREHOUSE_ID` | `<sql_warehouse_id>` | not set (only for running the data-prep SQL on a warehouse) |
| Source tables (data-prep notebook widgets) | `<source_catalog>.<source_schema>` | `manual_sandbox_dev.bronze` (`vacant_space`, `surplus`) |
| `GOVMOVE_AVAILABILITY_RULES` (optional JSON) | see `config.py` | vacant space: `Available`; surplus: `On the Market`, `Not on the Market` |

## Views (based on the Government Estate Intelligence template)

* **Estate Intelligence:** Estate overview (dataset cards, national map with layers, records by region/usage/organisation), Property explorer (search plus source-level detail tabs), Buildings, Land, Occupation, Vacant space, Surplus property, Co-location, Data quality.
* **Estate Planning & Decision Support:** a task landing page with a What If? panel, plus six tasks: Find space, Find co-location opportunities, Building utilisation explorer, Government footprint explorer, Vacant space finder (the postcode search) and Estate opportunity explorer.
* Not yet built from the template: the AI Estate Assistant (question and answer), the organisation-to-property relationship network diagram, and the header search box.

Additional settings: `GOVMOVE_EVIDENCE_TABLE` (`<evidence_table_name>`, default `govmove_property_evidence`), `GOVMOVE_PRIORITY_TABLE` (`<priority_results_table>`, default `property_priority_results`), and `GOVMOVE_*_CLEAN_TABLE` for the cleaned property, building, land and occupation tables.

## Files

* `main.py`: app entry point (GOV.UK header, mode navigation). `estate_views.py`, `planning_views.py`: views. `data_access.py`: Spark session, cached queries, location resolution.
* `app.py`: legacy single-page postcode finder, kept for reference.
* `govmove_core.py`: `normalise_postcode`, `get_postcode_coordinates`, `calculate_straight_line_distance`, and the Spark filter/search functions.
* `config.py`: configuration.
* `app.yaml`, `requirements.txt`: app runtime.
* `tests/test_govmove_core.py`: unit tests.
* The notebook **GovMove Data Preparation** (in the parent folder) builds the cleaned view and the tables the app reads.

## How it works

1. **Data prep (notebook).**
   * `vw_govmove_property_locations` unions vacant-space and surplus records, normalises postcodes and parses dates.
   * It classifies each record's coordinates and converts genuine Northern Ireland Irish Grid (EPSG:29903) `NI Easting`/`NI Northing` to BNG with `st_transform`. Records that cannot be compared reliably are labelled (`coordinate_status`, `coordinate_note`).
   * The view is materialised as `govmove_property_locations`.
   * `govmove_postcode_centroids` holds the mean BNG Easting/Northing of current AddressBase Premium address points per postcode. AddressBase Premium Northern Ireland (BT) addresses are already in BNG, so all postcodes and properties share one CRS.
2. **App.**
   * The postcode is normalised and validated, then resolved to BNG.
   * Filtering, `sqrt((E2-E1)^2 + (N2-N1)^2)`, the distance filter, sorting and the limit all run in Spark. Only the final results are converted to pandas.
   * Latitude/longitude are used only to draw the map.

Distances are straight-line, not road or travelling distance.

## Deploying as a Databricks App

1. Run the **GovMove Data Preparation** notebook. It creates the view and the two tables, and runs the unit tests.
2. Edit `app.yaml` with the values for your environment.
3. Grant the app's service principal (shown on the app's **Overview** page) read access:
   ```sql
   GRANT USE CATALOG ON CATALOG <catalog_name> TO `<app-service-principal-id>`;
   GRANT USE SCHEMA ON SCHEMA <catalog_name>.<schema_name> TO `<app-service-principal-id>`;
   GRANT SELECT ON TABLE <catalog_name>.<schema_name>.<property_table_name> TO `<app-service-principal-id>`;
   GRANT SELECT ON TABLE <catalog_name>.<schema_name>.<postcode_lookup_table_name> TO `<app-service-principal-id>`;
   -- optional fallback lookup:
   GRANT USE CATALOG ON CATALOG address_dev TO `<app-service-principal-id>`;
   GRANT USE SCHEMA ON SCHEMA address_dev.bronze TO `<app-service-principal-id>`;
   GRANT SELECT ON TABLE address_dev.bronze.addressbasepremium TO `<app-service-principal-id>`;
   ```
   If `GOVMOVE_COMPUTE` is a cluster ID, also give the service principal **Can Attach To** on that cluster.
4. Deploy from the workspace folder:
   ```
   databricks apps get govmove --output JSON          # compute must be ACTIVE
   databricks apps start govmove                      # only if compute is STOPPED
   databricks apps deploy govmove --source-code-path /Workspace/Users/<user>/govmove
   ```
   You can also click **Deploy** on the app page in the Databricks UI.
5. Open the app URL. Share it with users through the app's **Permissions** (Can Use).

## Running the tests

```
pip install pytest databricks-connect==15.4.*
pytest -q tests
```

The Spark distance tests skip automatically when no Spark session is available.
