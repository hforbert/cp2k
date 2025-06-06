!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
MODULE xc_derivatives

   USE input_section_types,             ONLY: section_vals_get_subs_vals2,&
                                              section_vals_type,&
                                              section_vals_val_get
   USE kinds,                           ONLY: dp
   USE xc_b97,                          ONLY: b97_lda_eval,&
                                              b97_lda_info,&
                                              b97_lsd_eval,&
                                              b97_lsd_info
   USE xc_cs1,                          ONLY: cs1_lda_eval,&
                                              cs1_lda_info,&
                                              cs1_lsd_eval,&
                                              cs1_lsd_info
   USE xc_derivative_set_types,         ONLY: xc_derivative_set_type
   USE xc_exchange_gga,                 ONLY: xgga_eval,&
                                              xgga_info
   USE xc_hcth,                         ONLY: hcth_lda_eval,&
                                              hcth_lda_info
   USE xc_ke_gga,                       ONLY: ke_gga_info,&
                                              ke_gga_lda_eval,&
                                              ke_gga_lsd_eval
   USE xc_libxc,                        ONLY: libxc_lda_eval,&
                                              libxc_lda_info,&
                                              libxc_lsd_eval,&
                                              libxc_lsd_info
   USE xc_lyp,                          ONLY: lyp_lda_eval,&
                                              lyp_lda_info,&
                                              lyp_lsd_eval,&
                                              lyp_lsd_info
   USE xc_lyp_adiabatic,                ONLY: lyp_adiabatic_lda_eval,&
                                              lyp_adiabatic_lda_info,&
                                              lyp_adiabatic_lsd_eval,&
                                              lyp_adiabatic_lsd_info
   USE xc_optx,                         ONLY: optx_lda_eval,&
                                              optx_lda_info,&
                                              optx_lsd_eval,&
                                              optx_lsd_info
   USE xc_pade,                         ONLY: pade_info,&
                                              pade_init,&
                                              pade_lda_pw_eval,&
                                              pade_lsd_pw_eval
   USE xc_pbe,                          ONLY: pbe_lda_eval,&
                                              pbe_lda_info,&
                                              pbe_lsd_eval,&
                                              pbe_lsd_info
   USE xc_perdew86,                     ONLY: p86_lda_eval,&
                                              p86_lda_info
   USE xc_perdew_wang,                  ONLY: perdew_wang_info,&
                                              perdew_wang_lda_eval,&
                                              perdew_wang_lsd_eval
   USE xc_perdew_zunger,                ONLY: pz_info,&
                                              pz_lda_eval,&
                                              pz_lsd_eval
   USE xc_rho_cflags_types,             ONLY: xc_rho_cflags_setall,&
                                              xc_rho_cflags_type
   USE xc_rho_set_types,                ONLY: xc_rho_set_get,&
                                              xc_rho_set_type
   USE xc_tfw,                          ONLY: tfw_lda_eval,&
                                              tfw_lda_info,&
                                              tfw_lsd_eval,&
                                              tfw_lsd_info
   USE xc_thomas_fermi,                 ONLY: thomas_fermi_info,&
                                              thomas_fermi_lda_eval,&
                                              thomas_fermi_lsd_eval
   USE xc_tpss,                         ONLY: tpss_lda_eval,&
                                              tpss_lda_info
   USE xc_vwn,                          ONLY: vwn_lda_eval,&
                                              vwn_lda_info,&
                                              vwn_lsd_eval,&
                                              vwn_lsd_info
   USE xc_xalpha,                       ONLY: xalpha_info,&
                                              xalpha_lda_eval,&
                                              xalpha_lsd_eval
   USE xc_xbecke88,                     ONLY: xb88_lda_eval,&
                                              xb88_lda_info,&
                                              xb88_lsd_eval,&
                                              xb88_lsd_info
   USE xc_xbecke88_long_range,          ONLY: xb88_lr_lda_eval,&
                                              xb88_lr_lda_info,&
                                              xb88_lr_lsd_eval,&
                                              xb88_lr_lsd_info
   USE xc_xbecke88_lr_adiabatic,        ONLY: xb88_lr_adiabatic_lda_eval,&
                                              xb88_lr_adiabatic_lda_info,&
                                              xb88_lr_adiabatic_lsd_eval,&
                                              xb88_lr_adiabatic_lsd_info
   USE xc_xbecke_roussel,               ONLY: xbecke_roussel_lda_eval,&
                                              xbecke_roussel_lda_info,&
                                              xbecke_roussel_lsd_eval,&
                                              xbecke_roussel_lsd_info
   USE xc_xbeef,                        ONLY: xbeef_lda_eval,&
                                              xbeef_lda_info,&
                                              xbeef_lsd_eval,&
                                              xbeef_lsd_info
   USE xc_xbr_pbe_lda_hole_t_c_lr,      ONLY: xbr_pbe_lda_hole_tc_lr_lda_eval,&
                                              xbr_pbe_lda_hole_tc_lr_lda_info,&
                                              xbr_pbe_lda_hole_tc_lr_lsd_eval,&
                                              xbr_pbe_lda_hole_tc_lr_lsd_info
   USE xc_xlda_hole_t_c_lr,             ONLY: xlda_hole_t_c_lr_lda_eval,&
                                              xlda_hole_t_c_lr_lda_info,&
                                              xlda_hole_t_c_lr_lsd_eval,&
                                              xlda_hole_t_c_lr_lsd_info
   USE xc_xpbe_hole_t_c_lr,             ONLY: xpbe_hole_t_c_lr_lda_eval,&
                                              xpbe_hole_t_c_lr_lda_info,&
                                              xpbe_hole_t_c_lr_lsd_eval,&
                                              xpbe_hole_t_c_lr_lsd_info
   USE xc_xwpbe,                        ONLY: xwpbe_lda_eval,&
                                              xwpbe_lda_info,&
                                              xwpbe_lsd_eval,&
                                              xwpbe_lsd_info
#include "../base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   LOGICAL, PARAMETER          :: debug_this_module = .FALSE.
   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'xc_derivatives'

   PUBLIC :: xc_functional_get_info, xc_functionals_eval, xc_functionals_get_needs

CONTAINS

! **************************************************************************************************
!> \brief get the information about the given functional
!> \param functional the functional you want info about
!> \param lsd if you are using lsd or lda
!> \param reference the reference to the acticle where the functional is
!>        explained
!> \param shortform the short definition of the functional
!> \param needs the flags corresponding to the inputs needed by this
!>        functional are set to true (the flags not needed aren't touched)
!> \param max_deriv the maximal derivative available
!> \param print_warn whether to print warnings (mainly relevant for libxc)
!> \author fawzi
! **************************************************************************************************
   SUBROUTINE xc_functional_get_info(functional, lsd, reference, shortform, &
                                     needs, max_deriv, print_warn)
      TYPE(section_vals_type), POINTER                   :: functional
      LOGICAL, INTENT(in)                                :: lsd
      CHARACTER(LEN=*), INTENT(OUT), OPTIONAL            :: reference, shortform
      TYPE(xc_rho_cflags_type), INTENT(inout), OPTIONAL  :: needs
      INTEGER, INTENT(out), OPTIONAL                     :: max_deriv
      LOGICAL, INTENT(IN), OPTIONAL                      :: print_warn

      INTEGER                                            :: i_param
      REAL(kind=dp)                                      :: r_param

      CPASSERT(ASSOCIATED(functional))
      SELECT CASE (functional%section%name)
      CASE ("BECKE97")
         IF (lsd) THEN
            CALL b97_lsd_info(reference=reference, shortform=shortform, &
                              needs=needs, max_deriv=max_deriv, b97_params=functional)
         ELSE
            CALL b97_lda_info(reference=reference, shortform=shortform, &
                              needs=needs, max_deriv=max_deriv, b97_params=functional)
         END IF
      CASE ("BECKE88_LR_ADIABATIC")
         IF (lsd) THEN
            CALL xb88_lr_adiabatic_lsd_info(reference=reference, shortform=shortform, &
                                            needs=needs, max_deriv=max_deriv)
         ELSE
            CALL xb88_lr_adiabatic_lda_info(reference=reference, shortform=shortform, &
                                            needs=needs, max_deriv=max_deriv)
         END IF
      CASE ("LYP_ADIABATIC")
         IF (lsd) THEN
            CALL lyp_adiabatic_lsd_info(reference=reference, shortform=shortform, &
                                        needs=needs, max_deriv=max_deriv)
         ELSE
            CALL lyp_adiabatic_lda_info(reference=reference, shortform=shortform, &
                                        needs=needs, max_deriv=max_deriv)
         END IF
      CASE ("BEEF")
         IF (lsd) THEN
            CALL xbeef_lsd_info(reference=reference, shortform=shortform, &
                                needs=needs, max_deriv=max_deriv)
         ELSE
            CALL xbeef_lda_info(reference=reference, shortform=shortform, &
                                needs=needs, max_deriv=max_deriv)
         END IF
      CASE ("BECKE88")
         IF (lsd) THEN
            CALL xb88_lsd_info(reference=reference, shortform=shortform, &
                               needs=needs, max_deriv=max_deriv)
         ELSE
            CALL xb88_lda_info(reference=reference, shortform=shortform, &
                               needs=needs, max_deriv=max_deriv)
         END IF
      CASE ("BECKE88_LR")
         IF (lsd) THEN
            CALL xb88_lr_lsd_info(reference=reference, shortform=shortform, &
                                  needs=needs, max_deriv=max_deriv)
         ELSE
            CALL xb88_lr_lda_info(reference=reference, shortform=shortform, &
                                  needs=needs, max_deriv=max_deriv)
         END IF
      CASE ("LYP")
         IF (lsd) THEN
            CALL lyp_lsd_info(reference=reference, shortform=shortform, &
                              needs=needs, max_deriv=max_deriv)
         ELSE
            CALL lyp_lda_info(reference=reference, shortform=shortform, &
                              needs=needs, max_deriv=max_deriv)
         END IF
      CASE ("PADE")
         CALL pade_info(reference, shortform, lsd=lsd, needs=needs)
      CASE ("HCTH")
         CALL section_vals_val_get(functional, "PARAMETER_SET", i_val=i_param)
         CPASSERT(.NOT. lsd)
         CALL hcth_lda_info(i_param, reference, shortform, needs, max_deriv)
      CASE ("OPTX")
         IF (lsd) THEN
            CALL optx_lsd_info(reference, shortform, needs, max_deriv)
         ELSE
            CALL optx_lda_info(reference, shortform, needs, max_deriv)
         END IF
      CASE ("CS1")
         IF (lsd) THEN
            CALL cs1_lsd_info(reference, shortform, needs, max_deriv)
         ELSE
            CALL cs1_lda_info(reference, shortform, needs=needs, max_deriv=max_deriv)
         END IF
      CASE ("XGGA")
         CALL section_vals_val_get(functional, "FUNCTIONAL", i_val=i_param)
         CALL xgga_info(i_param, lsd, reference, shortform, needs, max_deriv)
      CASE ("KE_GGA")
         CALL section_vals_val_get(functional, "FUNCTIONAL", i_val=i_param)
         CALL ke_gga_info(i_param, lsd, reference, shortform, needs, max_deriv)
      CASE ("P86C")
         IF (lsd) THEN
            CPABORT("BP functional not implemented with LSD")
         END IF
         CALL p86_lda_info(reference, shortform, needs, max_deriv)
      CASE ("PW92")
         CALL section_vals_val_get(functional, "PARAMETRIZATION", i_val=i_param)
         CALL section_vals_val_get(functional, "SCALE", r_val=r_param)
         CALL perdew_wang_info(i_param, lsd, reference, shortform, needs, max_deriv, &
                               r_param)
      CASE ("PZ81")
         CALL section_vals_val_get(functional, "PARAMETRIZATION", i_val=i_param)
         CALL pz_info(i_param, lsd, reference, shortform, needs, max_deriv)
      CASE ("TFW")
         IF (lsd) THEN
            CALL tfw_lsd_info(reference, shortform, needs, max_deriv)
         ELSE
            CALL tfw_lda_info(reference, shortform, needs, max_deriv)
         END IF
      CASE ("TF")
         CALL thomas_fermi_info(lsd, reference, shortform, needs, max_deriv)
      CASE ("VWN")
         IF (lsd) THEN
            CALL vwn_lsd_info(reference, shortform, needs, max_deriv)
         ELSE
            CALL vwn_lda_info(reference, shortform, needs, max_deriv)
         END IF
      CASE ("XALPHA")
         CALL section_vals_val_get(functional, "XA", r_val=r_param)
         CALL xalpha_info(lsd, reference, shortform, needs, max_deriv, &
                          xa_parameter=r_param)
      CASE ("TPSS")
         IF (lsd) THEN
            CPABORT("TPSS functional not implemented with LSD. Use the LIBXC version instead.")
         ELSE
            CALL tpss_lda_info(functional, reference, shortform, needs, max_deriv)
         END IF
      CASE ("PBE")
         IF (lsd) THEN
            CALL pbe_lsd_info(functional, reference, shortform, needs, max_deriv)
         ELSE
            CALL pbe_lda_info(functional, reference, shortform, needs, max_deriv)
         END IF
      CASE ("XWPBE")
         IF (lsd) THEN
            CALL xwpbe_lsd_info(reference, shortform, needs, max_deriv)
         ELSE
            CALL xwpbe_lda_info(reference, shortform, needs, max_deriv)
         END IF
      CASE ("BECKE_ROUSSEL")
         IF (lsd) THEN
            CALL xbecke_roussel_lsd_info(reference, shortform, needs, max_deriv)
         ELSE
            CALL xbecke_roussel_lda_info(reference, shortform, needs, max_deriv)
         END IF
      CASE ("LDA_HOLE_T_C_LR")
         IF (lsd) THEN
            CALL xlda_hole_t_c_lr_lsd_info(reference, shortform, needs, max_deriv)
         ELSE
            CALL xlda_hole_t_c_lr_lda_info(reference, shortform, needs, max_deriv)
         END IF
      CASE ("PBE_HOLE_T_C_LR")
         IF (lsd) THEN
            CALL xpbe_hole_t_c_lr_lsd_info(reference, shortform, needs, max_deriv)
         ELSE
            CALL xpbe_hole_t_c_lr_lda_info(reference, shortform, needs, max_deriv)
         END IF
      CASE ("GV09")
         IF (lsd) THEN
            CALL xbr_pbe_lda_hole_tc_lr_lsd_info(reference, shortform, needs, max_deriv)
         ELSE
            CALL xbr_pbe_lda_hole_tc_lr_lda_info(reference, shortform, needs, max_deriv)
         END IF
      CASE default
         ! If the functional has not been implemented internally, it's from LibXC
         IF (lsd) THEN
            CALL libxc_lsd_info(functional, reference, shortform, needs, max_deriv, print_warn)
         ELSE
            CALL libxc_lda_info(functional, reference, shortform, needs, max_deriv, print_warn)
         END IF
      END SELECT
   END SUBROUTINE xc_functional_get_info

! **************************************************************************************************
!> \brief evaluate a functional (and its derivatives)
!> \param functional a section that describes the functional to be added
!> \param lsd if a local spin desnity is performed
!> \param rho_set a rho set where all the arguments needed by this functional
!>        should be valid (which argument are needed can be found with
!>        xc_functional_get_info)
!> \param deriv_set place where to store the functional derivatives (they are
!>        added to the derivatives)
!> \param deriv_order degree of the derivative that should be evaluated,
!>        if positive all the derivatives up to the given degree are evaluated,
!>        if negative only the given degree is requested (but to simplify
!>        the code all the derivatives might be calculated, you should ignore
!>        them when adding derivatives of various functionals they might contain
!>        the derivative of just one functional)
!> \par History
!>      11.2003 created [fawzi]
!> \author fawzi
! **************************************************************************************************
   SUBROUTINE xc_functional_eval(functional, lsd, rho_set, deriv_set, deriv_order)

      TYPE(section_vals_type), POINTER                   :: functional
      LOGICAL, INTENT(in)                                :: lsd
      TYPE(xc_rho_set_type), INTENT(IN)                  :: rho_set
      TYPE(xc_derivative_set_type), INTENT(IN)           :: deriv_set
      INTEGER, INTENT(IN)                                :: deriv_order

      CHARACTER(len=*), PARAMETER :: routineN = 'xc_functional_eval'

      INTEGER                                            :: handle, i_param
      LOGICAL                                            :: fun_active
      REAL(KIND=dp)                                      :: density_cut, gradient_cut, r_param

      CALL timeset(routineN, handle)

      CALL xc_rho_set_get(rho_set, rho_cutoff=density_cut, &
                          drho_cutoff=gradient_cut)
      CALL section_vals_val_get(functional, "_SECTION_PARAMETERS_", &
                                l_val=fun_active)
      IF (.NOT. fun_active) THEN
         CALL timestop(handle)
         RETURN
      END IF

      SELECT CASE (functional%section%name)
      CASE ("BECKE97")
         IF (lsd) THEN
            CALL b97_lsd_eval(rho_set, deriv_set, deriv_order, functional)
         ELSE
            CALL b97_lda_eval(rho_set, deriv_set, deriv_order, functional)
         END IF
      CASE ("BECKE88_LR_ADIABATIC")
         IF (lsd) THEN
            CALL xb88_lr_adiabatic_lsd_eval(rho_set, deriv_set, deriv_order, functional)
         ELSE
            CALL xb88_lr_adiabatic_lda_eval(rho_set, deriv_set, deriv_order, functional)
         END IF
      CASE ("LYP_ADIABATIC")
         IF (lsd) THEN
            CALL lyp_adiabatic_lsd_eval(rho_set, deriv_set, deriv_order, functional)
         ELSE
            CALL lyp_adiabatic_lda_eval(rho_set, deriv_set, deriv_order, functional)
         END IF
      CASE ("BECKE88")
         IF (lsd) THEN
            CALL xb88_lsd_eval(rho_set, deriv_set, deriv_order, functional)
         ELSE
            CALL xb88_lda_eval(rho_set, deriv_set, deriv_order, functional)
         END IF
      CASE ("BEEF")
         IF (lsd) THEN
            CALL xbeef_lsd_eval(rho_set, deriv_set, deriv_order, functional)
         ELSE
            CALL xbeef_lda_eval(rho_set, deriv_set, deriv_order, functional)
         END IF
      CASE ("BECKE88_LR")
         IF (lsd) THEN
            CALL xb88_lr_lsd_eval(rho_set, deriv_set, deriv_order, functional)
         ELSE
            CALL xb88_lr_lda_eval(rho_set, deriv_set, deriv_order, functional)
         END IF
      CASE ("LYP")
         IF (lsd) THEN
            CALL lyp_lsd_eval(rho_set, deriv_set, deriv_order, functional)
         ELSE
            CALL lyp_lda_eval(rho_set, deriv_set, deriv_order, functional)
         END IF
      CASE ("PADE")
         CALL pade_init(density_cut)
         IF (lsd) THEN
            CALL pade_lsd_pw_eval(deriv_set, rho_set, deriv_order)
         ELSE
            CALL pade_lda_pw_eval(deriv_set, rho_set, deriv_order)
         END IF
      CASE ("HCTH")
         CPASSERT(.NOT. lsd)
         CALL section_vals_val_get(functional, "PARAMETER_SET", i_val=i_param)
         CALL hcth_lda_eval(i_param, rho_set, deriv_set, deriv_order)
      CASE ("OPTX")
         IF (lsd) THEN
            CALL optx_lsd_eval(rho_set, deriv_set, deriv_order, functional)
         ELSE
            CALL optx_lda_eval(rho_set, deriv_set, deriv_order, functional)
         END IF
      CASE ("CS1")
         IF (lsd) THEN
            CALL cs1_lsd_eval(rho_set, deriv_set, deriv_order)
         ELSE
            CALL cs1_lda_eval(rho_set, deriv_set, deriv_order)
         END IF
      CASE ("XGGA")
         CALL section_vals_val_get(functional, "FUNCTIONAL", i_val=i_param)
         CALL xgga_eval(i_param, lsd, rho_set, deriv_set, deriv_order)
      CASE ("KE_GGA")
         CALL section_vals_val_get(functional, "FUNCTIONAL", i_val=i_param)
         IF (lsd) THEN
            CALL ke_gga_lsd_eval(i_param, rho_set, deriv_set, deriv_order)
         ELSE
            CALL ke_gga_lda_eval(i_param, rho_set, deriv_set, deriv_order)
         END IF
      CASE ("P86C")
         CPASSERT(.NOT. lsd)
         CALL p86_lda_eval(rho_set, deriv_set, deriv_order, functional)
      CASE ("PW92")
         CALL section_vals_val_get(functional, "PARAMETRIZATION", i_val=i_param)
         CALL section_vals_val_get(functional, "SCALE", r_val=r_param)
         IF (lsd) THEN
            CALL perdew_wang_lsd_eval(i_param, rho_set, deriv_set, deriv_order, &
                                      r_param)
         ELSE
            CALL perdew_wang_lda_eval(i_param, rho_set, deriv_set, deriv_order, &
                                      r_param)
         END IF
      CASE ("PZ81")
         CALL section_vals_val_get(functional, "PARAMETRIZATION", i_val=i_param)
         IF (lsd) THEN
            CALL pz_lsd_eval(i_param, rho_set, deriv_set, deriv_order, functional)
         ELSE
            CALL pz_lda_eval(i_param, rho_set, deriv_set, deriv_order, functional)
         END IF
      CASE ("TFW")
         IF (lsd) THEN
            CALL tfw_lsd_eval(rho_set, deriv_set, deriv_order)
         ELSE
            CALL tfw_lda_eval(rho_set, deriv_set, deriv_order)
         END IF
      CASE ("TF")
         IF (lsd) THEN
            CALL thomas_fermi_lsd_eval(rho_set, deriv_set, deriv_order)
         ELSE
            CALL thomas_fermi_lda_eval(rho_set, deriv_set, deriv_order)
         END IF
      CASE ("VWN")
         IF (lsd) THEN
            CALL vwn_lsd_eval(rho_set, deriv_set, deriv_order, functional)
         ELSE
            CALL vwn_lda_eval(rho_set, deriv_set, deriv_order, functional)
         END IF
      CASE ("XALPHA")
         CALL section_vals_val_get(functional, "XA", r_val=r_param)
         IF (lsd) THEN
            CALL xalpha_lsd_eval(rho_set, deriv_set, deriv_order, &
                                 xa_parameter=r_param, xa_params=functional)
         ELSE
            CALL xalpha_lda_eval(rho_set, deriv_set, deriv_order, &
                                 xa_parameter=r_param, xa_params=functional)
         END IF
      CASE ("TPSS")
         IF (lsd) THEN
            CPABORT("TPSS functional not implemented with LSD. Use the LIBXC version instead.")
         ELSE
            CALL tpss_lda_eval(rho_set, deriv_set, deriv_order, functional)
         END IF
      CASE ("PBE")
         IF (lsd) THEN
            CALL pbe_lsd_eval(rho_set, deriv_set, deriv_order, functional)
         ELSE
            CALL pbe_lda_eval(rho_set, deriv_set, deriv_order, functional)
         END IF
      CASE ("XWPBE")
         IF (lsd) THEN
            CALL xwpbe_lsd_eval(rho_set, deriv_set, deriv_order, functional)
         ELSE
            CALL xwpbe_lda_eval(rho_set, deriv_set, deriv_order, functional)
         END IF
      CASE ("BECKE_ROUSSEL")
         IF (lsd) THEN
            CALL xbecke_roussel_lsd_eval(rho_set, deriv_set, deriv_order, functional)
         ELSE
            CALL xbecke_roussel_lda_eval(rho_set, deriv_set, deriv_order, functional)
         END IF
      CASE ("LDA_HOLE_T_C_LR")
         IF (lsd) THEN
            CALL xlda_hole_t_c_lr_lsd_eval(rho_set, deriv_set, deriv_order, functional)
         ELSE
            CALL xlda_hole_t_c_lr_lda_eval(rho_set, deriv_set, deriv_order, functional)
         END IF
      CASE ("PBE_HOLE_T_C_LR")
         IF (lsd) THEN
            CALL xpbe_hole_t_c_lr_lsd_eval(rho_set, deriv_set, deriv_order, functional)
         ELSE
            CALL xpbe_hole_t_c_lr_lda_eval(rho_set, deriv_set, deriv_order, functional)
         END IF
      CASE ("GV09")
         IF (lsd) THEN
            CALL xbr_pbe_lda_hole_tc_lr_lsd_eval(rho_set, deriv_set, deriv_order, &
                                                 functional)
         ELSE
            CALL xbr_pbe_lda_hole_tc_lr_lda_eval(rho_set, deriv_set, deriv_order, &
                                                 functional)
         END IF
      CASE default
         ! If functional not natively supported, ask LibXC
         IF (lsd) THEN
            CALL libxc_lsd_eval(rho_set, deriv_set, deriv_order, functional)
         ELSE
            CALL libxc_lda_eval(rho_set, deriv_set, deriv_order, functional)
         END IF
      END SELECT

      CALL timestop(handle)
   END SUBROUTINE xc_functional_eval

! **************************************************************************************************
!> \brief ...
!> \param functionals a section containing the functional combination to be
!>        applied
!> \param lsd if a local spin desnity is performed
!> \param rho_set a rho set where all the arguments needed by this functional
!>        should be valid (which argument are needed can be found with
!>        xc_functional_get_info)
!> \param deriv_set place where to store the functional derivatives (they are
!>        added to the derivatives)
!> \param deriv_order degree of the derivative that should be evaluated,
!>        if positive all the derivatives up to the given degree are evaluated,
!>        if negative only the given degree is requested (but to simplify
!>        the code all the derivatives might be calculated, you should ignore
!>        them when adding derivatives of various functionals they might contain
!>        the derivative of just one functional)
!> \author fawzi
! **************************************************************************************************
   SUBROUTINE xc_functionals_eval(functionals, lsd, rho_set, deriv_set, &
                                  deriv_order)
      TYPE(section_vals_type), POINTER                   :: functionals
      LOGICAL, INTENT(in)                                :: lsd
      TYPE(xc_rho_set_type), INTENT(IN)                  :: rho_set
      TYPE(xc_derivative_set_type), INTENT(IN)           :: deriv_set
      INTEGER, INTENT(in)                                :: deriv_order

      INTEGER                                            :: ifun
      TYPE(section_vals_type), POINTER                   :: xc_fun

      CPASSERT(ASSOCIATED(functionals))
      ifun = 0
      DO
         ifun = ifun + 1
         xc_fun => section_vals_get_subs_vals2(functionals, i_section=ifun)
         IF (.NOT. ASSOCIATED(xc_fun)) EXIT
         CALL xc_functional_eval(xc_fun, &
                                 lsd=lsd, &
                                 rho_set=rho_set, &
                                 deriv_set=deriv_set, &
                                 deriv_order=deriv_order)
      END DO
   END SUBROUTINE xc_functionals_eval

! **************************************************************************************************
!> \brief ...
!> \param functionals a section containing the functional combination to be
!>        applied
!> \param lsd if a local spin desnity is performed
!> \param calc_potential set, if potential calculation will be carried out later.
!>        helps to save memory and flops. defaults to false.
!> \return ...
!> \author fawzi
! **************************************************************************************************
   FUNCTION xc_functionals_get_needs(functionals, lsd, calc_potential) &
      RESULT(needs)
      TYPE(section_vals_type), POINTER                   :: functionals
      LOGICAL, INTENT(in)                                :: lsd
      LOGICAL, INTENT(in), OPTIONAL                      :: calc_potential
      TYPE(xc_rho_cflags_type)                           :: needs

      INTEGER                                            :: ifun
      LOGICAL                                            :: my_calc_potential
      TYPE(section_vals_type), POINTER                   :: xc_fun

      my_calc_potential = .FALSE.
      IF (PRESENT(calc_potential)) my_calc_potential = calc_potential

      CPASSERT(ASSOCIATED(functionals))
      CALL xc_rho_cflags_setall(needs, .FALSE.)

      ifun = 0
      DO
         ifun = ifun + 1
         xc_fun => section_vals_get_subs_vals2(functionals, i_section=ifun)
         IF (.NOT. ASSOCIATED(xc_fun)) EXIT
         CALL xc_functional_get_info(xc_fun, lsd=lsd, needs=needs)
      END DO

      IF (my_calc_potential) THEN
         IF (lsd) THEN
            needs%rho_spin = .TRUE.
            needs%tau_spin = needs%tau_spin .OR. needs%tau
         ELSE
            needs%rho = .TRUE.
         END IF
         IF (needs%norm_drho .OR. needs%norm_drho_spin) THEN
            IF (lsd) THEN
               needs%drho_spin = .TRUE.
            ELSE
               needs%drho = .TRUE.
            END IF
         END IF
      END IF
   END FUNCTION xc_functionals_get_needs

END MODULE xc_derivatives
