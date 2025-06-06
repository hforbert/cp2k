!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief module that contains the definitions of the scf types
!> \par History
!>      02.2003 created [fawzi]
!> \author fawzi
! **************************************************************************************************
MODULE qs_density_mixing_types
   USE ao_util,                         ONLY: exp_radius
   USE input_constants,                 ONLY: broy_mix,&
                                              direct_p_mix,&
                                              gaussian,&
                                              kerker_mix,&
                                              multisec_mix,&
                                              no_mix,&
                                              pulay_mix
   USE input_keyword_types,             ONLY: keyword_create,&
                                              keyword_release,&
                                              keyword_type
   USE input_section_types,             ONLY: section_add_keyword,&
                                              section_create,&
                                              section_type,&
                                              section_vals_type,&
                                              section_vals_val_get
   USE input_val_types,                 ONLY: real_t
   USE kinds,                           ONLY: default_string_length,&
                                              dp
   USE qs_rho_atom_types,               ONLY: rho_atom_coeff
   USE string_utilities,                ONLY: s2a
#include "./base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   LOGICAL, PRIVATE, PARAMETER :: debug_this_module = .TRUE.

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'qs_density_mixing_types'

   INTEGER, PARAMETER, PUBLIC :: no_mixing_nr = 0, direct_mixing_nr = 1, &
                                 gspace_mixing_nr = 2, pulay_mixing_nr = 3, &
                                 broyden_mixing_nr = 4, &
                                 multisecant_mixing_nr = 6
   PUBLIC :: cp_1d_z_p_type, mixing_storage_create, mixing_storage_type, mixing_storage_release, create_mixing_section

   TYPE cp_1d_z_p_type
      COMPLEX(dp), DIMENSION(:), POINTER :: cc => NULL()
   END TYPE cp_1d_z_p_type

   TYPE mixing_storage_type
   INTEGER                                           :: ig_max = -1, ncall = -1, ncall_p(2) = -1, nbuffer = -1, n_simple_mix = -1, &
                                                           nskip_mixing = -1, p_metric_method = -1
      INTEGER, POINTER, DIMENSION(:)                    :: ig_global_index => NULL()
      LOGICAL                                           :: gmix_p = .FALSE.
      LOGICAL, POINTER, DIMENSION(:)                    :: paw => NULL()
      CHARACTER(len=15)                                 :: iter_method = ""
      REAL(KIND=dp)                                     :: alpha = -1.0_dp, bconst = -1.0_dp, beta = -1.0_dp, broy_w0 = -1.0_dp, &
                                                           max_g2 = -1.0_dp, max_gvec_exp = -1.0_dp, pulay_alpha = -1.0_dp, &
                                                           pulay_beta = -1.0_dp, r_step = -1.0_dp, reg_par = -1.0_dp, &
                                                           sigma_max = -1.0_dp, wc = -1.0_dp, wmax = -1.0_dp
      REAL(KIND=dp), DIMENSION(:), POINTER              :: p_metric => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER              :: kerker_factor => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER              :: special_metric => NULL()
      REAL(KIND=dp), DIMENSION(:, :), POINTER           :: weight => NULL()
      REAL(KIND=dp), DIMENSION(:, :), POINTER           :: norm_res_buffer => NULL()
      REAL(KIND=dp), DIMENSION(:, :, :), POINTER        :: fmat => NULL(), gmat => NULL(), pulay_matrix => NULL(), smat => NULL()
      !
      INTEGER                                           :: nat_local = -1, max_shell = -1
      REAL(KIND=dp), DIMENSION(:, :, :), POINTER        :: acharge => NULL()
      REAL(KIND=dp), DIMENSION(:, :, :), POINTER        :: dacharge => NULL()
      REAL(KIND=dp), DIMENSION(:, :, :), POINTER        :: dfbroy => NULL()
      REAL(KIND=dp), DIMENSION(:, :, :), POINTER        :: ubroy => NULL()
      REAL(KIND=dp), DIMENSION(:, :), POINTER           :: abroy => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER              :: wbroy => NULL()
      INTEGER, DIMENSION(:), POINTER                    :: atlist => NULL()
      !
      TYPE(cp_1d_z_p_type), DIMENSION(:), POINTER       :: last_res => NULL(), rhoin => NULL(), rhoin_old => NULL()
      TYPE(cp_1d_z_p_type), DIMENSION(:, :), POINTER    :: delta_res => NULL(), u_vec => NULL(), z_vec => NULL()
      TYPE(cp_1d_z_p_type), DIMENSION(:, :), POINTER    :: drho_buffer => NULL(), rhoin_buffer => NULL(), res_buffer => NULL()
      !
      TYPE(rho_atom_coeff), DIMENSION(:, :), POINTER    :: cpc_h_lastres => NULL(), cpc_s_lastres => NULL()
      TYPE(rho_atom_coeff), DIMENSION(:, :), POINTER    :: cpc_h_in => NULL(), cpc_s_in => NULL()
      TYPE(rho_atom_coeff), DIMENSION(:, :), POINTER    :: cpc_h_old => NULL(), cpc_s_old => NULL()
      TYPE(rho_atom_coeff), DIMENSION(:, :, :), POINTER :: cpc_h_in_buffer => NULL(), cpc_s_in_buffer => NULL()
      TYPE(rho_atom_coeff), DIMENSION(:, :, :), POINTER :: cpc_h_res_buffer => NULL(), cpc_s_res_buffer => NULL()
      TYPE(rho_atom_coeff), DIMENSION(:, :, :), POINTER :: dcpc_h_in => NULL(), dcpc_s_in => NULL()
   END TYPE mixing_storage_type

CONTAINS

! **************************************************************************************************
!> \brief creates a mixing_storage
!> \param mixing_store ...
!> \param mixing_section ...
!> \param mixing_method ...
!> \param ecut ...
!> \par History
!>      05.2009 created [MI]
!> \author [MI]
! **************************************************************************************************
   SUBROUTINE mixing_storage_create(mixing_store, mixing_section, mixing_method, ecut)
      TYPE(mixing_storage_type), INTENT(OUT)             :: mixing_store
      TYPE(section_vals_type), POINTER                   :: mixing_section
      INTEGER, INTENT(IN)                                :: mixing_method
      REAL(dp), INTENT(IN)                               :: ecut

      REAL(dp)                                           :: alpha, eps, gcut

      mixing_store%nbuffer = 0
      mixing_store%n_simple_mix = 0
      mixing_store%ncall = 0
      mixing_store%ncall_p = 0
      mixing_store%alpha = 1.0_dp
      mixing_store%pulay_beta = 1.0_dp
      mixing_store%beta = 1.0_dp
      mixing_store%iter_method = "NoMix"
      mixing_store%max_g2 = 2._dp*ecut
      mixing_store%gmix_p = .FALSE.

      NULLIFY (mixing_store%p_metric)
      NULLIFY (mixing_store%kerker_factor)
      NULLIFY (mixing_store%special_metric)
      NULLIFY (mixing_store%pulay_matrix)
      NULLIFY (mixing_store%weight)
      NULLIFY (mixing_store%fmat)
      NULLIFY (mixing_store%gmat)
      NULLIFY (mixing_store%smat)
      NULLIFY (mixing_store%acharge)
      NULLIFY (mixing_store%dacharge)
      NULLIFY (mixing_store%dfbroy)
      NULLIFY (mixing_store%ubroy)
      NULLIFY (mixing_store%abroy)
      NULLIFY (mixing_store%wbroy)
      NULLIFY (mixing_store%atlist)
      NULLIFY (mixing_store%last_res)
      NULLIFY (mixing_store%rhoin)
      NULLIFY (mixing_store%rhoin_old)
      NULLIFY (mixing_store%delta_res)
      NULLIFY (mixing_store%u_vec)
      NULLIFY (mixing_store%z_vec)
      NULLIFY (mixing_store%drho_buffer)
      NULLIFY (mixing_store%rhoin_buffer)
      NULLIFY (mixing_store%res_buffer)
      NULLIFY (mixing_store%norm_res_buffer)
      NULLIFY (mixing_store%ig_global_index)
      NULLIFY (mixing_store%paw)
      NULLIFY (mixing_store%cpc_h_in)
      NULLIFY (mixing_store%cpc_s_in)
      NULLIFY (mixing_store%cpc_h_old)
      NULLIFY (mixing_store%cpc_s_old)
      NULLIFY (mixing_store%dcpc_h_in)
      NULLIFY (mixing_store%dcpc_s_in)
      NULLIFY (mixing_store%cpc_h_lastres)
      NULLIFY (mixing_store%cpc_s_lastres)
      NULLIFY (mixing_store%cpc_h_in_buffer)
      NULLIFY (mixing_store%cpc_s_in_buffer)
      NULLIFY (mixing_store%cpc_h_res_buffer)
      NULLIFY (mixing_store%cpc_s_res_buffer)

      CALL section_vals_val_get(mixing_section, "ALPHA", r_val=mixing_store%alpha)
      CALL section_vals_val_get(mixing_section, "BETA", r_val=mixing_store%beta)
      CALL section_vals_val_get(mixing_section, "N_SIMPLE_MIX", i_val=mixing_store%n_simple_mix)
      CALL section_vals_val_get(mixing_section, "NBUFFER", i_val=mixing_store%nbuffer)
      CALL section_vals_val_get(mixing_section, "NSKIP", i_val=mixing_store%nskip_mixing)
      CALL section_vals_val_get(mixing_section, "MAX_GVEC_EXP", r_val=mixing_store%max_gvec_exp)
      CALL section_vals_val_get(mixing_section, "GMIX_P", l_val=mixing_store%gmix_p)

      IF (mixing_store%max_gvec_exp > 0._dp) THEN
         alpha = 0.25_dp/mixing_store%max_gvec_exp
         eps = 1.e-4_dp
         gcut = exp_radius(3, alpha, eps, 1.0_dp)
         mixing_store%max_g2 = gcut*gcut
      END IF

      SELECT CASE (mixing_method)
      CASE (gspace_mixing_nr)
         mixing_store%nbuffer = 1
      CASE (pulay_mixing_nr)
         CALL section_vals_val_get(mixing_section, "PULAY_ALPHA", r_val=mixing_store%pulay_alpha)
         CALL section_vals_val_get(mixing_section, "PULAY_BETA", r_val=mixing_store%pulay_beta)
      CASE (broyden_mixing_nr)
         CALL section_vals_val_get(mixing_section, "BROY_W0", r_val=mixing_store%broy_w0)
         mixing_store%bconst = 20.0_dp
      CASE (multisecant_mixing_nr)
         CALL section_vals_val_get(mixing_section, "REGULARIZATION", r_val=mixing_store%reg_par)
         CALL section_vals_val_get(mixing_section, "MAX_STEP", r_val=mixing_store%sigma_max)
         CALL section_vals_val_get(mixing_section, "R_FACTOR", r_val=mixing_store%r_step)
      END SELECT

   END SUBROUTINE mixing_storage_create

! **************************************************************************************************
!> \brief releases a mixing_storage
!> \param mixing_store ...
!> \par History
!>      05.2009 created [MI]
!> \author [MI]
! **************************************************************************************************
   SUBROUTINE mixing_storage_release(mixing_store)
      TYPE(mixing_storage_type), INTENT(INOUT)           :: mixing_store

      INTEGER                                            :: i, j, k

      IF (ASSOCIATED(mixing_store%kerker_factor)) THEN
         DEALLOCATE (mixing_store%kerker_factor)
      END IF

      IF (ASSOCIATED(mixing_store%special_metric)) THEN
         DEALLOCATE (mixing_store%special_metric)
      END IF

      IF (ASSOCIATED(mixing_store%pulay_matrix)) THEN
         DEALLOCATE (mixing_store%pulay_matrix)
      END IF

      IF (ASSOCIATED(mixing_store%rhoin_buffer)) THEN
         DO i = 1, SIZE(mixing_store%rhoin_buffer, 2)
            DO j = 1, SIZE(mixing_store%rhoin_buffer, 1)
               DEALLOCATE (mixing_store%rhoin_buffer(j, i)%cc)
            END DO
         END DO
         DEALLOCATE (mixing_store%rhoin_buffer)
      END IF

      IF (ASSOCIATED(mixing_store%paw)) THEN
         DEALLOCATE (mixing_store%paw)
      END IF
      IF (ASSOCIATED(mixing_store%cpc_h_in)) THEN
         DO j = 1, SIZE(mixing_store%cpc_h_in, 2)
         DO k = 1, SIZE(mixing_store%cpc_h_in, 1)
            IF (ASSOCIATED(mixing_store%cpc_h_in(k, j)%r_coef)) THEN
               DEALLOCATE (mixing_store%cpc_h_in(k, j)%r_coef)
               DEALLOCATE (mixing_store%cpc_s_in(k, j)%r_coef)
            END IF
         END DO
         END DO
         DEALLOCATE (mixing_store%cpc_h_in)
         DEALLOCATE (mixing_store%cpc_s_in)
      END IF
      IF (ASSOCIATED(mixing_store%cpc_h_old)) THEN
         DO j = 1, SIZE(mixing_store%cpc_h_old, 2)
         DO k = 1, SIZE(mixing_store%cpc_h_old, 1)
            IF (ASSOCIATED(mixing_store%cpc_h_old(k, j)%r_coef)) THEN
               DEALLOCATE (mixing_store%cpc_h_old(k, j)%r_coef)
               DEALLOCATE (mixing_store%cpc_s_old(k, j)%r_coef)
            END IF
         END DO
         END DO
         DEALLOCATE (mixing_store%cpc_h_old)
         DEALLOCATE (mixing_store%cpc_s_old)
      END IF
      IF (ASSOCIATED(mixing_store%cpc_h_in_buffer)) THEN
         DO i = 1, SIZE(mixing_store%cpc_h_in_buffer, 3)
         DO j = 1, SIZE(mixing_store%cpc_h_in_buffer, 2)
         DO k = 1, SIZE(mixing_store%cpc_h_in_buffer, 1)
            IF (ASSOCIATED(mixing_store%cpc_h_in_buffer(k, j, i)%r_coef)) THEN
               DEALLOCATE (mixing_store%cpc_h_in_buffer(k, j, i)%r_coef)
               DEALLOCATE (mixing_store%cpc_s_in_buffer(k, j, i)%r_coef)
            END IF
         END DO
         END DO
         END DO
         DEALLOCATE (mixing_store%cpc_h_in_buffer)
         DEALLOCATE (mixing_store%cpc_s_in_buffer)
      END IF
      IF (ASSOCIATED(mixing_store%cpc_h_res_buffer)) THEN
         DO i = 1, SIZE(mixing_store%cpc_h_res_buffer, 3)
         DO j = 1, SIZE(mixing_store%cpc_h_res_buffer, 2)
         DO k = 1, SIZE(mixing_store%cpc_h_res_buffer, 1)
            IF (ASSOCIATED(mixing_store%cpc_h_res_buffer(k, j, i)%r_coef)) THEN
               DEALLOCATE (mixing_store%cpc_h_res_buffer(k, j, i)%r_coef)
               DEALLOCATE (mixing_store%cpc_s_res_buffer(k, j, i)%r_coef)
            END IF
         END DO
         END DO
         END DO
         DEALLOCATE (mixing_store%cpc_h_res_buffer)
         DEALLOCATE (mixing_store%cpc_s_res_buffer)
      END IF

      IF (ASSOCIATED(mixing_store%dcpc_h_in)) THEN
         DO i = 1, SIZE(mixing_store%dcpc_h_in, 3)
         DO j = 1, SIZE(mixing_store%dcpc_h_in, 2)
         DO k = 1, SIZE(mixing_store%dcpc_h_in, 1)
            IF (ASSOCIATED(mixing_store%dcpc_h_in(k, j, i)%r_coef)) THEN
               DEALLOCATE (mixing_store%dcpc_h_in(k, j, i)%r_coef)
               DEALLOCATE (mixing_store%dcpc_s_in(k, j, i)%r_coef)
            END IF
         END DO
         END DO
         END DO
         DEALLOCATE (mixing_store%dcpc_h_in)
         DEALLOCATE (mixing_store%dcpc_s_in)
      END IF
      IF (ASSOCIATED(mixing_store%cpc_h_lastres)) THEN
         DO j = 1, SIZE(mixing_store%cpc_h_lastres, 2)
         DO k = 1, SIZE(mixing_store%cpc_h_lastres, 1)
            IF (ASSOCIATED(mixing_store%cpc_h_lastres(k, j)%r_coef)) THEN
               DEALLOCATE (mixing_store%cpc_h_lastres(k, j)%r_coef)
               DEALLOCATE (mixing_store%cpc_s_lastres(k, j)%r_coef)
            END IF
         END DO
         END DO
         DEALLOCATE (mixing_store%cpc_h_lastres)
         DEALLOCATE (mixing_store%cpc_s_lastres)
      END IF

      IF (ASSOCIATED(mixing_store%res_buffer)) THEN
         DO i = 1, SIZE(mixing_store%res_buffer, 2)
            DO j = 1, SIZE(mixing_store%res_buffer, 1)
               DEALLOCATE (mixing_store%res_buffer(j, i)%cc)
            END DO
         END DO
         DEALLOCATE (mixing_store%res_buffer)
      END IF

      IF (ASSOCIATED(mixing_store%norm_res_buffer)) THEN
         DEALLOCATE (mixing_store%norm_res_buffer)
      END IF

      IF (ASSOCIATED(mixing_store%ig_global_index)) THEN
         DEALLOCATE (mixing_store%ig_global_index)
      END IF

      IF (ASSOCIATED(mixing_store%drho_buffer)) THEN
         DO i = 1, SIZE(mixing_store%drho_buffer, 2)
            DO j = 1, SIZE(mixing_store%drho_buffer, 1)
               DEALLOCATE (mixing_store%drho_buffer(j, i)%cc)
            END DO
         END DO
         DEALLOCATE (mixing_store%drho_buffer)
      END IF

      IF (ASSOCIATED(mixing_store%last_res)) THEN
         DO i = 1, SIZE(mixing_store%last_res)
            DEALLOCATE (mixing_store%last_res(i)%cc)
         END DO
         DEALLOCATE (mixing_store%last_res)
      END IF

      IF (ASSOCIATED(mixing_store%rhoin)) THEN
         DO i = 1, SIZE(mixing_store%rhoin)
            DEALLOCATE (mixing_store%rhoin(i)%cc)
         END DO
         DEALLOCATE (mixing_store%rhoin)
      END IF

      IF (ASSOCIATED(mixing_store%rhoin_old)) THEN
         DO i = 1, SIZE(mixing_store%rhoin_old)
            DEALLOCATE (mixing_store%rhoin_old(i)%cc)
         END DO
         DEALLOCATE (mixing_store%rhoin_old)
      END IF

      IF (ASSOCIATED(mixing_store%p_metric)) THEN
         DEALLOCATE (mixing_store%p_metric)
      END IF

      IF (ASSOCIATED(mixing_store%weight)) THEN
         DEALLOCATE (mixing_store%weight)
      END IF

      IF (ASSOCIATED(mixing_store%fmat)) THEN
         DEALLOCATE (mixing_store%fmat)
      END IF

      IF (ASSOCIATED(mixing_store%acharge)) THEN
         DEALLOCATE (mixing_store%acharge)
      END IF
      IF (ASSOCIATED(mixing_store%dacharge)) THEN
         DEALLOCATE (mixing_store%dacharge)
      END IF
      IF (ASSOCIATED(mixing_store%dfbroy)) THEN
         DEALLOCATE (mixing_store%dfbroy)
      END IF
      IF (ASSOCIATED(mixing_store%ubroy)) THEN
         DEALLOCATE (mixing_store%ubroy)
      END IF
      IF (ASSOCIATED(mixing_store%abroy)) THEN
         DEALLOCATE (mixing_store%abroy)
      END IF
      IF (ASSOCIATED(mixing_store%wbroy)) THEN
         DEALLOCATE (mixing_store%wbroy)
      END IF
      IF (ASSOCIATED(mixing_store%atlist)) THEN
         DEALLOCATE (mixing_store%atlist)
      END IF

      IF (ASSOCIATED(mixing_store%delta_res)) THEN
         DO i = 1, SIZE(mixing_store%delta_res, 2)
            DO j = 1, SIZE(mixing_store%delta_res, 1)
               DEALLOCATE (mixing_store%delta_res(j, i)%cc)
            END DO
         END DO
         DEALLOCATE (mixing_store%delta_res)
      END IF

      IF (ASSOCIATED(mixing_store%u_vec)) THEN
         DO i = 1, SIZE(mixing_store%u_vec, 2)
            DO j = 1, SIZE(mixing_store%u_vec, 1)
               DEALLOCATE (mixing_store%u_vec(j, i)%cc)
            END DO
         END DO
         DEALLOCATE (mixing_store%u_vec)
      END IF

      IF (ASSOCIATED(mixing_store%z_vec)) THEN
         DO i = 1, SIZE(mixing_store%z_vec, 2)
            DO j = 1, SIZE(mixing_store%z_vec, 1)
               DEALLOCATE (mixing_store%z_vec(j, i)%cc)
            END DO
         END DO
         DEALLOCATE (mixing_store%z_vec)
      END IF

   END SUBROUTINE mixing_storage_release

! **************************************************************************************************
!> \brief      Create CP2K input section for the mixing of the density matrix to
!>             be used only with diagonalization methods, i.e. not with OT
!> \param section ...
!> \param ls_scf ...
!> \date       20.02.2009
!> \par History
!>      02.2015 moved here from input_cp2k_dft.F, modified for use in LS SCF
!>              [Patrick Seewald]
!> \author     MI
!> \version    1.0
! **************************************************************************************************
   SUBROUTINE create_mixing_section(section, ls_scf)

      TYPE(section_type), POINTER                        :: section
      LOGICAL, INTENT(IN), OPTIONAL                      :: ls_scf

      CHARACTER(LEN=default_string_length)               :: section_name
      INTEGER                                            :: default_mix
      LOGICAL                                            :: ls
      TYPE(keyword_type), POINTER                        :: keyword

      CPASSERT(.NOT. ASSOCIATED(section))

      IF (PRESENT(ls_scf)) THEN
         IF (ls_scf) THEN
            ls = .TRUE.
         ELSE
            ls = .FALSE.
         END IF
      ELSE
         ls = .FALSE.
      END IF

      IF (ls) THEN
         section_name = "RHO_MIXING"
      ELSE
         section_name = "MIXING"
      END IF

      CALL section_create(section, __LOCATION__, &
                          name=section_name, &
                          description="Define type and parameters for mixing "// &
                          "procedures to be applied to the density matrix. Normally, "// &
                          "only one type of mixing method should be accepted. The mixing "// &
                          "procedures activated by this section are only active for diagonalization "// &
                          "methods and linear scaling SCF, i.e. not with minimization methods based "// &
                          "on OT.", &
                          n_keywords=16, &
                          n_subsections=0, &
                          repeats=.FALSE.)

      NULLIFY (keyword)

      CALL keyword_create(keyword, __LOCATION__, &
                          name="_SECTION_PARAMETERS_", &
                          description="Controls the activation of the mixing procedure", &
                          usage="&MIXING ON", &
                          default_l_val=.TRUE., &
                          lone_keyword_l_val=.TRUE.)
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      IF (.NOT. ls) THEN
         default_mix = direct_p_mix
      ELSE
         default_mix = broy_mix
      END IF

      CALL keyword_create(keyword, __LOCATION__, &
                          name="METHOD", &
                          description="Mixing method to be applied", &
                          repeats=.FALSE., &
                          usage="METHOD KERKER_MIXING", &
                          default_i_val=default_mix, &
                          enum_c_vals=s2a("NONE", &
                                          "DIRECT_P_MIXING", &
                                          "KERKER_MIXING", &
                                          "PULAY_MIXING", &
                                          "BROYDEN_MIXING", &
                                          "MULTISECANT_MIXING"), &
                          enum_i_vals=(/no_mix, direct_p_mix, kerker_mix, pulay_mix, broy_mix, &
                                        multisec_mix/), &
                          enum_desc=s2a("No mixing is applied", &
                                        "Direct mixing of new and old density matrices", &
                                        "Mixing of the potential in reciprocal space using the Kerker damping", &
                                        "Pulay mixing", "Broyden mixing", &
                                        "Multisecant scheme for mixing"))

      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, &
                          name="ALPHA", &
                          description="Fraction of new density to be included", &
                          repeats=.FALSE., &
                          n_var=1, &
                          type_of_var=real_t, &
                          default_r_val=0.4_dp, &
                          usage="ALPHA 0.2")
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, &
                          name="BETA", &
                          description="Denominator parameter in Kerker damping "// &
                          "introduced to suppress charge sloshing: "// &
                          "rho_mix(g) = rho_in(g) + alpha*g^2/(g^2 + beta^2)*(rho_out(g)-rho_in(g))", &
                          repeats=.FALSE., &
                          n_var=1, &
                          type_of_var=real_t, &
                          default_r_val=0.5_dp, &
                          unit_str="bohr^-1", &
                          usage="BETA 1.5")
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, &
                          name="PULAY_ALPHA", &
                          description="Fraction of new density to be added to the Pulay expansion", &
                          repeats=.FALSE., &
                          n_var=1, &
                          type_of_var=real_t, &
                          default_r_val=0.0_dp, &
                          usage="PULAY_ALPHA 0.2")
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, &
                          name="PULAY_BETA", &
                          description="Fraction of residual contribution to be added to Pulay expansion", &
                          repeats=.FALSE., &
                          n_var=1, &
                          type_of_var=real_t, &
                          default_r_val=1.0_dp, &
                          usage="PULAY_BETA 0.2")
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="NMIXING", &
                          description="Minimal number of density mixing (should be greater than 0), "// &
                          "before starting DIIS", &
                          usage="NMIXING 1", default_i_val=2)
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="NBUFFER", &
                          variants=s2a("NPULAY", "NBROYDEN", "NMULTISECANT"), &
                          description="Number of previous steps stored for the actual mixing scheme", &
                          usage="NBUFFER 2", default_i_val=4)
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, &
                          name="BROY_W0", &
                          description=" w0 parameter used in Broyden mixing", &
                          repeats=.FALSE., &
                          n_var=1, &
                          type_of_var=real_t, &
                          default_r_val=0.01_dp, &
                          usage="BROY_W0 0.03")
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, &
                          name="BROY_WREF", &
                          description="", &
                          repeats=.FALSE., &
                          n_var=1, &
                          type_of_var=real_t, &
                          default_r_val=100.0_dp, &
                          usage="BROY_WREF 0.2")
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, &
                          name="BROY_WMAX", &
                          description="", &
                          repeats=.FALSE., &
                          n_var=1, &
                          type_of_var=real_t, &
                          default_r_val=30.0_dp, &
                          usage="BROY_WMAX 10.0")
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, &
                          name="REGULARIZATION", &
                          description="Regularization parameter to stabilize "// &
                          "the inversion of the residual matrix {Yn^t Yn} in the "// &
                          "multisecant mixing scheme (noise)", &
                          repeats=.FALSE., &
                          n_var=1, &
                          type_of_var=real_t, &
                          default_r_val=0.00001_dp, &
                          usage="REGULARIZATION 0.000001")
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, &
                          name="MAX_STEP", &
                          description="Upper bound for the magnitude of the "// &
                          "unpredicted step size in the update by the "// &
                          "multisecant mixing scheme", &
                          repeats=.FALSE., &
                          n_var=1, &
                          type_of_var=real_t, &
                          default_r_val=0.1_dp, &
                          usage="MAX_STEP .2")
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, &
                          name="R_FACTOR", &
                          description="Control factor for the magnitude of the "// &
                          "unpredicted step size in the update by the "// &
                          "multisecant mixing scheme", &
                          repeats=.FALSE., &
                          n_var=1, &
                          type_of_var=real_t, &
                          default_r_val=0.05_dp, &
                          usage="R_FACTOR .12")
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="NSKIP", &
                          variants=(/"NSKIP_MIXING"/), &
                          description="Number of initial iteration for which the mixing is skipped", &
                          usage="NSKIP 10", default_i_val=0)
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="N_SIMPLE_MIX", &
                          variants=(/"NSIMPLEMIX"/), &
                          description="Number of kerker damping iterations before starting other mixing procedures", &
                          usage="NSIMPLEMIX", default_i_val=0)
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="MAX_GVEC_EXP", &
                          description="Restricts the G-space mixing to lower part of G-vector spectrum,"// &
                          " up to a G0, by assigning the exponent of the Gaussian that can be "// &
                          "represented by vectors smaller than G0 within a certain accuracy. ", &
                          repeats=.FALSE., &
                          n_var=1, &
                          type_of_var=real_t, &
                          default_r_val=-1._dp, &
                          usage="MAX_GVEC_EXP 3.")
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="GMIX_P", &
                          description="Activate the mixing of the density matrix, using the same"// &
                          " mixing coefficient applied for the g-space mixing.", &
                          repeats=.FALSE., &
                          lone_keyword_l_val=.TRUE., &
                          default_l_val=.FALSE., &
                          usage="GMIX_P")
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

   END SUBROUTINE create_mixing_section

END MODULE qs_density_mixing_types
