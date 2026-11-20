# ================================================================
# DESNZ Energy Consumption, EPC and Deprivation Analysis
# ================================================================
#
# DATA SOURCES
#
# 1. Domestic electricity consumption (2024)
#    Source: Department for Energy Security and Net Zero (DESNZ)
#    Dataset: Postcode-level electricity statistics, 2024
#    File: Postcode_level_all_meters_electricity_2024.csv
#    Download:
#    https://www.gov.uk/government/statistics/postcode-level-electricity-statistics-2024
#
# 2. Energy Performance Certificates (EPC)
#    Source: Ministry of Housing, Communities and Local Government
#    Dataset: EPC lodgements by local authority and quarter
#    Period used: 2008–2024
#    File: apc_la_data.csv
#    Source:
#    https://www.gov.uk/government/collections/energy-performance-of-buildings-certificates
#
# 3. English Indices of Deprivation (2025)
#    Source: Ministry of Housing, Communities and Local Government
#    Dataset: File 2 - IoD2025 Domains of Deprivation
#    File: File_2_IoD2025 Domains of Deprivation.csv
#    Download:
#    https://deprivation.communities.gov.uk/download-all
#
# 4. ONS Postcode Directory
#    Source: Office for National Statistics
#    Dataset: ONS Postcode Directory (2025)
#    File: postcode_to_la.csv
#    Download:
#    https://geoportal.statistics.gov.uk/
#    Required fields: pcds (postcode), lad25cd (LA code)
#
# ================================================================
# REPRODUCING THE ANALYSIS
# ================================================================
#
# 1. Download the four datasets listed above.
# 2. Save them in the same directory, using the filenames above.
# 3. Set base_dir to the directory containing the datasets.
# 4. Install required R packages: data.table and ggplot2.
# 5. Run the script.
#
# METHODOLOGY
# - Analysis conducted at local authority level.
# - Electricity consumption measured as annual kWh per meter (2024).
# - EPC ratings aggregated across 2008–2024, with equal weighting
#   of individual lodgements.
# - Deprivation measured as the percentage of LSOAs within each
#   local authority falling in the most deprived 20% nationally.
# - Pearson and Spearman correlations calculated.
# - Multivariable linear regression used to examine associations.
#
# LIMITATIONS
# - EPC lodgements do not necessarily represent the housing stock.
# - Electricity consumption is not total household energy demand.
# - Postcode lookup uses 2025 local authority boundaries.
# - Results describe associations, not causal relationships.
#
# ================================================================

# Required: install.packages(c("data.table", "ggplot2"))
library(data.table)
library(ggplot2)

# EDIT THIS to the folder containing the four input CSV files.
base_dir <- "Hackathon 20-11-2026"
f <- function(x) file.path(base_dir, x)

clean_names <- function(x) {
  x <- tolower(trimws(sub("^\\ufeff", "", x)))
  gsub("(^_+|_+$)", "", gsub("[^a-z0-9]+", "_", x))
}
num <- function(x) suppressWarnings(as.numeric(gsub(",", "", as.character(x))))
postcode_key <- function(x) gsub("\\s+", "", toupper(trimws(as.character(x))))
find_col <- function(dt, options, label) {
  hits <- intersect(options, names(dt))
  if (!length(hits)) stop("Missing ", label, "; found: ", paste(names(dt), collapse = ", "))
  hits[1L]
}

# 1. Postcode electricity consumption, 2024.
elec <- fread(f("Postcode_level_all_meters_electricity_2024.csv"),
              select = c("Postcode", "Num_meters", "Total_cons_kwh"))
setnames(elec, clean_names(names(elec)))
elec[, `:=`(postcode = postcode_key(postcode),
            num_meters = num(num_meters), total_cons_kwh = num(total_cons_kwh))]
elec <- elec[postcode != "ALLPOSTCODES" & !is.na(postcode) &
               num_meters > 0 & is.finite(total_cons_kwh) & total_cons_kwh >= 0]

# The postcode-to-LA lookup is essential; this is a FOURTH input dataset.
# Use ONS Postcode Directory, saved as postcode_to_la.csv.
lookup <- fread(f("postcode_to_la.csv"))
setnames(lookup, clean_names(names(lookup)))
pc_col <- find_col(lookup, c("pcds", "pcd", "pcd2", "pcd7", "pcd8", "postcode"), "postcode")
la_col <- find_col(lookup, c("lad25cd", "lad24cd", "ladcd", "la_code", "local_authority_code"), "LA code")
lookup <- unique(lookup[, .(postcode = postcode_key(get(pc_col)),
                            la_code = as.character(get(la_col)))])
lookup <- lookup[!is.na(la_code) & la_code != "" & !is.na(postcode) & postcode != ""]
ambiguous <- lookup[, .N, by = postcode][N > 1L, postcode]
if (length(ambiguous)) {
  warning("Excluding ", length(ambiguous), " postcodes mapping to multiple LAs")
  lookup <- lookup[!postcode %in% ambiguous]
}
joined_elec <- merge(elec, lookup, by = "postcode")
if (!nrow(joined_elec)) stop("No postcode matches. Check lookup format")
coverage <- sum(joined_elec$num_meters) / sum(elec$num_meters)
message(sprintf("Electricity meter matching coverage: %.1f%%", 100 * coverage))
la_elec <- joined_elec[, .(electricity_kwh = sum(total_cons_kwh),
                           electricity_meters = sum(num_meters),
                           matched_postcodes = uniqueN(postcode)), by = la_code]
la_elec[, kwh_per_meter := electricity_kwh / electricity_meters]
rm(elec, joined_elec); invisible(gc())

# 2. EPC certificates: ALL AVAILABLE quarters up to and including 2024.
# Each lodgement counts equally, not each year or each property.
# Do not average quarterly percentages (which would overweight small quarters).
epc <- fread(f("apc_la_data.csv"), fill = TRUE)
setnames(epc, clean_names(names(epc)))
epc[, year := suppressWarnings(as.integer(sub("/.*$", "", quarter)))]
epc <- epc[!is.na(year) & year <= 2024 & year >= 2008 &
             !is.na(local_authority_code) & local_authority_code != ""]
bands <- letters[1:7]
for (col in bands) set(epc, j = col, value = num(epc[[col]]))
epc[, la_code := as.character(local_authority_code)]
la_epc <- epc[, lapply(.SD, function(x) sum(x, na.rm = TRUE)),
              by = la_code, .SDcols = bands]
la_epc[, epc_rated := rowSums(.SD), .SDcols = bands]
la_epc <- la_epc[epc_rated > 0]
la_epc[, `:=`(pct_epc_e_g = 100 * (e + f + g) / epc_rated,
              pct_epc_d_g = 100 * (d + e + f + g) / epc_rated,
              mean_epc_band = (a + 2*b + 3*c + 4*d + 5*e + 6*f + 7*g) / epc_rated)]

# 3. IoD 2025: share of each LA's LSOAs in England's most deprived 20%.
iod <- fread(f("File_2_IoD2025 Domains of Deprivation.csv"))
setnames(iod, clean_names(names(iod)))
la_field <- find_col(iod, c("local_authority_district_code_2024"), "IoD 2024 LA code")
iod[, la_code := as.character(iod[[la_field]])]
patterns <- c(
  imd = "^index_of_multiple_deprivation_imd_decile",
  income = "^income_decile",
  employment = "^employment_decile",
  education = "^education_skills_and_training_decile",
  health = "^health_deprivation_and_disability_decile",
  crime = "^crime_decile",
  housing_barriers = "^barriers_to_housing_and_services_decile",
  living_environment = "^living_environment_decile"
)
la_iod <- unique(iod[, .(la_code)])
for (label in names(patterns)) {
  hit <- grep(patterns[[label]], names(iod), value = TRUE)
  if (length(hit) != 1L) stop("Cannot identify IoD decile: ", label)
  iod[, (hit) := num(get(hit))]
  part <- iod[!is.na(get(hit)), .(share = 100 * mean(get(hit) <= 2)), by = la_code]
  setnames(part, "share", paste0("pct_lsoa_deprived_", label))
  la_iod <- merge(la_iod, part, by = "la_code", all.x = TRUE)
}

# 4. Join and describe coverage.
dat <- Reduce(function(x, y) merge(x, y, by = "la_code"),
              list(la_elec, la_epc, la_iod))
if (nrow(dat) < 20) stop("Too few matching LAs: check 2024/2025 boundary compatibility")
fwrite(dat, f("joined_la_data_equal_weight.csv"))
message("Matched LAs: ", nrow(dat))

# 5. Separate outcome-versus-deprivation correlations (not all pairwise pairs).
# Spearman is the primary descriptive correlation. BH-adjusted p-values
# address multiple comparisons within each outcome's 7 tests.
domains <- paste0("pct_lsoa_deprived_", setdiff(names(patterns), "imd"))
outcomes <- c("kwh_per_meter", "pct_epc_e_g")
cor_rows <- list()
for (outcome in outcomes) {
  for (domain in domains) {
    x <- dat[[outcome]]; y <- dat[[domain]]
    keep <- is.finite(x) & is.finite(y)
    if (sum(keep) < 4 || sd(x[keep]) == 0 || sd(y[keep]) == 0) next
    sp <- suppressWarnings(cor.test(x[keep], y[keep], method = "spearman", exact = FALSE))
    pe <- cor.test(x[keep], y[keep], method = "pearson")
    cor_rows[[length(cor_rows) + 1L]] <- data.table(
      outcome = outcome, domain = domain, n_la = sum(keep),
      spearman_rho = unname(sp$estimate), spearman_p = sp$p.value,
      pearson_r = unname(pe$estimate), pearson_p = pe$p.value)
  }
}
correlations <- rbindlist(cor_rows)
correlations[, spearman_p_bh := p.adjust(spearman_p, method = "BH"), by = outcome]
# Create a temporary column for absolute correlation strength
correlations[, abs_rho := abs(spearman_rho)]

# Sort by outcome, then strongest correlation first
setorder(correlations, outcome, -abs_rho)

# Remove temporary column
correlations[, abs_rho := NULL]
fwrite(correlations, f("outcome_deprivation_correlations.csv"))

# 6. Predictor dependence: Spearman matrix + VIF for full model.
# No automatic selection by p-value. Full model is exploratory and
# a pre-specified reduced model is reported alongside it.
cor_matrix <- cor(as.matrix(dat[, ..domains]), method = "spearman", use = "pairwise.complete.obs")
fwrite(data.table(variable = rownames(cor_matrix), cor_matrix, check.names = FALSE),
       f("deprivation_correlation_matrix.csv"))

vif_values <- function(model) {
  X <- model.matrix(model)[, -1, drop = FALSE]
  if (ncol(X) < 2L) return(data.table(predictor = colnames(X), vif = NA_real_))
  vals <- sapply(seq_len(ncol(X)), function(j) {
    r2 <- summary(lm(X[, j] ~ X[, -j, drop = FALSE]))$r.squared
    if (is.na(r2) || r2 >= 1) Inf else 1 / (1 - r2)
  })
  data.table(predictor = colnames(X), vif = as.numeric(vals))
}

# 7. Regression models: unweighted LA-level OLS as the main specification.
# Full: all seven deprivation domains (excluding composite IMD).
# Reduced: income, education and housing barriers chosen in advance for
# distinct policy mechanisms, NOT because of correlations/p-values.
# Consumption-plus-EPC model tests conditional association, not causality.
reduced <- paste0("pct_lsoa_deprived_", c("income", "education", "housing_barriers"))
specs <- list(
  electricity_full = list(y = "kwh_per_meter", x = domains),
  electricity_reduced = list(y = "kwh_per_meter", x = reduced),
  epc_full = list(y = "pct_epc_e_g", x = domains),
  epc_reduced = list(y = "pct_epc_e_g", x = reduced),
  electricity_plus_epc = list(y = "kwh_per_meter", x = c(reduced, "pct_epc_e_g"))
)
models <- list(); coef_rows <- list(); fit_rows <- list(); vif_rows <- list()
for (nm in names(specs)) {
  s <- specs[[nm]]
  cols <- c(s$y, s$x)
  d <- as.data.frame(dat[complete.cases(dat[, ..cols]), ..cols])
  if (nrow(d) <= length(s$x) + 5L) {
    warning("Skipping model with too few observations: ", nm); next
  }
  model <- lm(reformulate(s$x, response = s$y), data = d)
  models[[nm]] <- model
  sm <- summary(model)
  tab <- as.data.table(sm$coefficients, keep.rownames = "term")
  setnames(tab, c("Estimate", "Std. Error", "t value", "Pr(>|t|)"),
           c("estimate", "std_error", "t_value", "p_value"))
  tab[, model := nm]
  coef_rows[[nm]] <- tab
  fit_rows[[nm]] <- data.table(model = nm, n_la = nobs(model),
                               r_squared = sm$r.squared, adjusted_r_squared = sm$adj.r.squared,
                               residual_sd = sm$sigma)
  v <- vif_values(model)
  v[, model := nm]
  vif_rows[[nm]] <- v
}
fwrite(rbindlist(coef_rows, fill = TRUE), f("regression_coefficients.csv"))
fwrite(rbindlist(fit_rows), f("regression_model_summary.csv"))
fwrite(rbindlist(vif_rows), f("regression_vif.csv"))
saveRDS(models, f("regression_models.rds"))

# 8. Plots: all 14 outcome/domain relationships (not cherry-picked top p-values).
pdf(f("outcome_deprivation_scatterplots.pdf"), width = 9, height = 6)
for (outcome in outcomes) for (domain in domains) {
  row <- correlations[correlations$outcome == outcome & correlations$domain == domain]
  p <- ggplot(dat, aes(x = .data[[domain]], y = .data[[outcome]])) +
    geom_point(alpha = 0.55, colour = "steelblue") +
    geom_smooth(method = "lm", se = TRUE, colour = "firebrick") +
    labs(title = paste(outcome, "vs", domain),
         subtitle = sprintf("Spearman rho = %.2f; BH-adjusted p = %.3g",
                            row$spearman_rho, row$spearman_p_bh),
         x = "Share of LSOAs in most deprived national quintile (%)", y = outcome) +
    theme_minimal()
  print(p)
}
dev.off()

pdf(f("regression_diagnostics.pdf"), width = 9, height = 7)
for (nm in names(models)) {
  par(mfrow = c(2, 2))
  plot(models[[nm]], main = nm)
}
dev.off()

message("Finished. Outputs saved in: ", normalizePath(base_dir))
message("Cautions: equal certificate weights do not deduplicate properties; ",
        "EPCs are lodgements, not housing-stock prevalence; ",
        "electricity kWh/meter is not total household energy demand; ",
        "results are LA-level associations, not causal estimates.")

